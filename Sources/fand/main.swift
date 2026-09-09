import AppKit
import Foundation
import Network
import SMCCore

// Root daemon holding manual fan control, plus a localhost HTTP API.
// Only Auto and Max exist — no endpoint sets a low or custom RPM.
// Safety lives here, not in callers, because callers can ask for anything:
//  - TTL dead-man switch (default 15 min, max 2 h)
//  - 102 °C die failsafe
//  - targets are always each fan's F%dMx
//  - revert to auto on exit / SIGTERM

let port: UInt16 = 8765
let failsafeTemp: Float = 102
let defaultTTL: TimeInterval = 900
let maxTTL: TimeInterval = 7200
/// Bump when helper behavior changes so the app replaces a stale LaunchDaemon.
let daemonAPIVersion = 4

final class DaemonState: @unchecked Sendable {
    let fc: FanControl
    var expiresAt: Date? = nil
    /// True after TTL/failsafe until every fan is actually back in auto.
    var pendingAuto = false
    var revertBusy = false
    var lastRequest: String = "none"
    let lock = NSLock()
    init(_ fc: FanControl) { self.fc = fc }
    var ttlRemaining: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
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
    func shouldRevert() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pendingAuto { return true }
        guard let e = expiresAt else { return false }
        return Date() >= e
    }
    func isPendingAuto() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingAuto
    }
}

enum Runtime {
    static var state: DaemonState?
    static var timer: DispatchSourceTimer?
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
    let list = s.fc.allFans()
    let fans = list.map { f -> [String: Any] in
        ["index": f.index, "actualRPM": Double(f.actualRPM), "targetRPM": Double(f.targetRPM),
         "minRPM": Double(f.minRPM), "maxRPM": Double(f.maxRPM), "mode": f.mode]
    }
    let temps = s.fc.dieTemperatures().prefix(15).map { ["key": $0.key, "celsius": Double($0.celsius)] }
    return ["model": SMCConnection.hardwareModel(),
            "state": FanHealth.state(fans: list, manual: s.isManual).rawValue,
            "fans": fans,
            "topTemps": temps,
            "control": ["manual": s.isManual, "ttlRemaining": s.ttlRemaining ?? 0, "lastRequest": s.lastRequest],
            "failsafeC": failsafeTemp,
            "version": daemonAPIVersion]
}

func revertAllToAuto(_ s: DaemonState) {
    s.lock.lock()
    if s.revertBusy { s.lock.unlock(); return }
    s.revertBusy = true
    s.expiresAt = nil
    s.pendingAuto = true
    s.lock.unlock()
    defer { s.lock.synchronized { s.revertBusy = false } }

    do {
        try s.fc.setAllAuto()
        Thread.sleep(forTimeInterval: 0.15)
    } catch {
        print("fand: revert write failed (\(error)) — will retry")
        return
    }
    let stuck = s.fc.allFans().filter { $0.mode == 1 }
    if stuck.isEmpty {
        s.lock.synchronized { s.pendingAuto = false; s.lastRequest = "auto" }
        print("fand: reverted to auto")
    } else {
        print("fand: revert incomplete (fans \(stuck.map(\.index)) still mode 1) — will retry")
    }
}

/// Waits for each fan to reach the RPM it was *commanded*, not a fixed share of
/// max, so a machine already held fast by auto control is not mistaken for a
/// successful spin-up. `baseline` is RPM just before the write.
/// Returns (atTarget, waitedSeconds, per-fan before/after).
func awaitSpinUp(_ s: DaemonState,
                 baseline: [(index: Int, rpm: Float)] = [],
                 waitSeconds: TimeInterval = 10,
                 tolerance: Float = 0.97) -> (Bool, TimeInterval, [[String: Any]]) {
    func commanded(_ f: FanInfo) -> Float { f.targetRPM > 0 ? f.targetRPM : f.maxRPM }
    func reached(_ fans: [FanInfo]) -> Bool {
        guard !fans.isEmpty else { return false }
        return fans.allSatisfy { f in
            let target = commanded(f)
            guard target > 0 else { return true }
            return f.actualRPM >= target * tolerance
        }
    }
    func detail(_ fans: [FanInfo]) -> [[String: Any]] {
        fans.map { f in
            let before = baseline.first { $0.index == f.index }?.rpm
            var row: [String: Any] = ["index": f.index,
                                      "commandedRPM": Double(f.targetRPM),
                                      "actualRPM": Double(f.actualRPM),
                                      "reached": reached([f])]
            if let before {
                row["beforeRPM"] = Double(before)
                row["deltaRPM"] = Double(f.actualRPM - before)
            }
            return row
        }
    }
    let start = Date()
    while Date().timeIntervalSince(start) < waitSeconds {
        let fans = s.fc.allFans()
        if reached(fans) { return (true, Date().timeIntervalSince(start), detail(fans)) }
        Thread.sleep(forTimeInterval: 0.5)
    }
    let fans = s.fc.allFans()
    return (reached(fans), Date().timeIntervalSince(start), detail(fans))
}

func handleRequest(_ s: DaemonState, method: String, path: String, body: Data) -> (Int, [String: Any]) {
    // TTL and failsafe checks do SMC I/O, so they must stay outside the lock —
    // revertAllToAuto takes it itself. /max and /auto replace state, so skip them.
    let isControlPOST = method == "POST" && (path == "/max" || path == "/boost" || path == "/auto")
    if !isControlPOST, s.shouldRevert() { revertAllToAuto(s) }
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
    let b = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    if method == "GET", path == "/status" { return (200, statusPayload(s)) }
    if method == "GET", path == "/sensors" {
        let all = s.fc.temperatures().map { ["key": $0.key, "celsius": $0.celsius] }
        return (200, ["model": SMCConnection.hardwareModel(), "count": all.count, "sensors": all])
    }
    if method == "POST", path == "/auto" {
        revertAllToAuto(s)
        if s.isPendingAuto() {
            Thread.sleep(forTimeInterval: 0.3)
            revertAllToAuto(s)
        }
        if s.isPendingAuto() {
            return (500, ["ok": false, "error": "auto write did not stick — retrying"] as [String: Any])
        }
        return (200, ["ok": true, "status": statusPayload(s)] as [String: Any])
    }
    // /boost is an alias of /max.
    if method == "POST", path == "/max" || path == "/boost" {
        let ttl = min(max(jsonNumber(b["ttl_seconds"]) ?? defaultTTL, 60), maxTTL)
        let baseline = s.fc.allFans().map { (index: $0.index, rpm: $0.actualRPM) }
        do {
            try s.fc.setAllMax()
            s.lock.synchronized { s.expiresAt = Date().addingTimeInterval(ttl); s.pendingAuto = false; s.lastRequest = "max" }
            let (spunUp, waited, spinCheck) = awaitSpinUp(s, baseline: baseline)
            var payload = statusPayload(s)
            payload["spunUp"] = spunUp
            payload["spinWaitSeconds"] = waited
            payload["spinUpCheck"] = spinCheck
            return (200, ["ok": true, "ttl_seconds": ttl, "spunUp": spunUp, "spinWaitSeconds": waited, "spinUpCheck": spinCheck, "status": payload] as [String: Any])
        } catch {
            return (500, ["ok": false, "error": "\(error)"] as [String: Any])
        }
    }
    if method == "POST", path == "/set" {
        return (410, ["ok": false, "error": "removed: only Max (/max) and Auto (/auto) exist — no custom/low RPM is expressible"] as [String: Any])
    }
    return (404, ["ok": false, "error": "unknown \(method) \(path) (try /status, /sensors, /max, /auto)"] as [String: Any])
}

// --- TTL expiry (also checked lazily per request) ---
func startExpiryTimer(_ s: DaemonState) {
    // Dispatch timer: RunLoop timers do not fire reliably under launchd.
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    t.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(200))
    t.setEventHandler {
        if s.shouldRevert() { revertAllToAuto(s) }
        if s.manualSnapshot(), let hottest = hottestDie(s.fc), hottest >= failsafeTemp {
            print("fand: FAILSAFE \(hottest)C -> auto")
            revertAllToAuto(s)
        }
    }
    t.resume()
    Runtime.timer = t
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
    // launchd redirects stdout, which block-buffers print(); keep the log live.
    setvbuf(stdout, nil, _IONBF, 0)
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
