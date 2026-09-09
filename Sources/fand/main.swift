import AppKit
import Foundation
import Network
import SMCCore

// MARK: - fand: root daemon holding manual fan control + localhost HTTP API
// SAFE SUBSET ONLY: the only states are Auto (macOS default, do nothing)
// and Max (all fans at hardware-reported maximum). There is NO endpoint,
// now or ever, that sets a low or custom RPM — forcing low fans under load
// must not even be expressible.
// Safety lives HERE, not in callers (agents can ask; daemon decides):
//  - TTL dead-man switch (default 15 min, max 2 h) -> revert to auto
//  - 102 °C die failsafe -> revert to auto immediately
//  - Max only: targets are always each fan's F%dMx, never below
//  - revert-to-auto on exit / SIGTERM / sleep-wake handling

let port: UInt16 = 8765
let failsafeTemp: Float = 102
let defaultTTL: TimeInterval = 900
let maxTTL: TimeInterval = 7200

final class DaemonState: @unchecked Sendable {
    let fc: FanControl
    var expiresAt: Date? = nil
    var lastRequest: String = "none"
    let lock = NSLock()
    init(_ fc: FanControl) { self.fc = fc }
    var ttlRemaining: TimeInterval? {
        guard let e = expiresAt else { return nil }
        let r = e.timeIntervalSinceNow
        return r > 0 ? r : 0
    }
    var isManual: Bool { (ttlRemaining ?? 0) > 0 }
    func manualSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = expiresAt else { return false }
        return e.timeIntervalSinceNow > 0
    }
    func expiredSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = expiresAt else { return false }
        return Date() >= e
    }
}

enum Runtime {
    static var state: DaemonState?
    static func halt(_ why: String) {
        print("fand: \(why)")
        if let s = state { revertAllToAuto(s) }
        exit(0)
    }
}

func jsonValue(_ obj: Any) -> Any {
    switch obj {
    case let f as Float: return f.isFinite ? Double(f) : NSNull()
    case let d as Double: return d.isFinite ? d : NSNull()
    case let a as [Any]: return a.map(jsonValue)
    case let d as [String: Any]: return d.mapValues { jsonValue($0) }
    default: return obj
    }
}

func json(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: jsonValue(obj))) ?? Data("{}".utf8)
}

func jsonNumber(_ raw: Any?) -> Double? {
    switch raw {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return nil
    }
}

func hottestDie(_ fc: FanControl) -> Float? {
    fc.dieTemperatures().map(\.celsius).max()
}

func statusPayload(_ s: DaemonState) -> [String: Any] {
    let fans = s.fc.allFans().map { f -> [String: Any] in
        ["index": f.index, "actualRPM": Double(f.actualRPM), "targetRPM": Double(f.targetRPM),
         "minRPM": Double(f.minRPM), "maxRPM": Double(f.maxRPM), "mode": f.mode]
    }
    let temps = s.fc.dieTemperatures().prefix(15).map { ["key": $0.key, "celsius": Double($0.celsius)] }
    return ["model": SMCConnection.hardwareModel(),
            "fans": fans,
            "topTemps": temps,
            "control": ["manual": s.isManual, "ttlRemaining": s.ttlRemaining ?? 0, "lastRequest": s.lastRequest],
            "failsafeC": failsafeTemp]
}

func revertAllToAuto(_ s: DaemonState) {
    try? s.fc.setAllAuto()
    s.lock.synchronized { s.expiresAt = nil }
    print("fand: reverted to auto")
}

/// After commanding Max, fans need physical spin-up lag. Poll actual RPM
/// (up to `waitSeconds`) until every fan reaches 80% of its max.
/// Returns (spunUp, waitedSeconds).
func awaitSpinUp(_ s: DaemonState, waitSeconds: TimeInterval = 10) -> (Bool, TimeInterval) {
    let start = Date()
    while Date().timeIntervalSince(start) < waitSeconds {
        let fans = s.fc.allFans()
        if !fans.isEmpty, fans.allSatisfy({ $0.maxRPM <= 0 || $0.actualRPM >= $0.maxRPM * 0.8 }) {
            return (true, Date().timeIntervalSince(start))
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    let fans = s.fc.allFans()
    return (!fans.isEmpty && fans.allSatisfy({ $0.maxRPM <= 0 || $0.actualRPM >= $0.maxRPM * 0.8 }), Date().timeIntervalSince(start))
}

func handleRequest(_ s: DaemonState, method: String, path: String, body: Data) -> (Int, [String: Any]) {
    // expire TTL + thermal failsafe (SMC I/O happens OUTSIDE the lock;
    // revertAllToAuto takes the lock itself, so never call it under lock)
    if s.expiredSnapshot() { revertAllToAuto(s) }
    var failsafeHit: Float? = nil
    if s.manualSnapshot() {
        if let hottest = hottestDie(s.fc), hottest >= failsafeTemp {
            failsafeHit = hottest
            revertAllToAuto(s)
        }
    }
    if let h = failsafeHit {
        print("fand: FAILSAFE \(h)C -> auto")
        return (503, ["ok": false, "error": "thermal failsafe: die at \(h)C, reverted to auto"])
    }
    // NOTE: actual routing below (outside lock to avoid holding across SMC I/O)
    let b = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    if method == "GET", path == "/status" { return (200, statusPayload(s)) }
    if method == "GET", path == "/sensors" {
        let all = s.fc.temperatures().map { ["key": $0.key, "celsius": $0.celsius] }
        return (200, ["model": SMCConnection.hardwareModel(), "count": all.count, "sensors": all])
    }
    if method == "POST", path == "/auto" {
        do {
            try s.fc.setAllAuto()
        } catch {
            return (500, ["ok": false, "error": "\(error)"] as [String: Any])
        }
        s.lock.synchronized { s.expiresAt = nil; s.lastRequest = "auto" }
        return (200, ["ok": true, "status": statusPayload(s)] as [String: Any])
    }
    // Max only. /set is intentionally gone: no custom/low RPM path exists.
    // /max is the canonical name; /boost kept as an alias.
    if method == "POST", path == "/max" || path == "/boost" {
        let ttl = min(max(jsonNumber(b["ttl_seconds"]) ?? defaultTTL, 60), maxTTL)
        do {
            try s.fc.setAllMax()
            s.lock.synchronized { s.expiresAt = Date().addingTimeInterval(ttl); s.lastRequest = "max" }
            let (spunUp, waited) = awaitSpinUp(s)
            var payload = statusPayload(s)
            payload["spunUp"] = spunUp
            payload["spinWaitSeconds"] = waited
            return (200, ["ok": true, "ttl_seconds": ttl, "spunUp": spunUp, "spinWaitSeconds": waited, "status": payload] as [String: Any])
        } catch {
            return (500, ["ok": false, "error": "\(error)"] as [String: Any])
        }
    }
    if method == "POST", path == "/set" {
        return (410, ["ok": false, "error": "removed: only Max (/max) and Auto (/auto) exist — no custom/low RPM is expressible"] as [String: Any])
    }
    return (404, ["ok": false, "error": "unknown \(method) \(path) (try /status, /sensors, /max, /auto)"] as [String: Any])
}

// --- TTL expiry timer (body above handles expiry lazily per request too) ---
func startExpiryTimer(_ s: DaemonState) {
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        if s.expiredSnapshot() { revertAllToAuto(s) }
        if s.manualSnapshot(), let hottest = hottestDie(s.fc), hottest >= failsafeTemp {
            revertAllToAuto(s)
            print("fand: FAILSAFE \(hottest)C -> auto")
        }
    }
}

// --- Minimal HTTP/1.0 server on 127.0.0.1 via Network.framework ---
func startHTTP(_ s: DaemonState, port: UInt16) throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: params)
    listener.service = nil
    listener.newConnectionHandler = { c in
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let lines = req.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            let method = parts.count > 0 ? String(parts[0]) : "GET"
            let path = parts.count > 1 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
            var body = Data()
            if let range = req.range(of: "\r\n\r\n") { body = Data(req[range.upperBound...].utf8) }
            let (code, obj) = handleRequest(s, method: method, path: path, body: body)
            let payload = json(obj)
            let text = code == 200 ? "OK" : "Error"
            let head = "HTTP/1.0 \(code) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            var resp = Data(head.utf8); resp.append(payload)
            c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
        }
    }
    listener.start(queue: .global())
    print("fand: listening on 127.0.0.1:\(port)")
}

// --- main ---
do {
    let fc = try FanControl()
    print("fand: model=\(SMCConnection.hardwareModel()) fans=\(fc.fanCount) modeKey=\(fc.hw.modeKeyFormat) ftst=\(fc.hw.ftstAvailable) euid=\(geteuid())")
    if geteuid() != 0 { print("fand: WARNING not root — writes will fail. Run via sudo or install LaunchDaemon.") }
    let state = DaemonState(fc)
    Runtime.state = state
    signal(SIGTERM) { _ in Runtime.halt("SIGTERM") }
    signal(SIGINT) { _ in Runtime.halt("SIGINT") }
    startExpiryTimer(state)
    // re-assert Max after wake if TTL still valid (firmware drops manual across sleep)
    let nc = NSWorkspace.shared.notificationCenter
    _ = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        if state.manualSnapshot() {
            print("fand: wake — re-asserting Max (TTL still valid)")
            try? state.fc.setAllMax()
        } else {
            print("fand: wake — staying Auto (no valid TTL)")
        }
    }
    try startHTTP(state, port: port)
    RunLoop.main.run()
} catch {
    print("fand: fatal \(error)"); exit(1)
}

extension NSLock {
    func synchronized(_ b: () -> Void) { lock(); defer { unlock() }; b() }
}
