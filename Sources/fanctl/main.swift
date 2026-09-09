import Foundation
import SMCCore

// fanctl: CLI for humans + scripts + agents.
// Prefers the fand HTTP API (127.0.0.1:8765) when reachable; falls back to direct SMC.
// Writes require root when going direct: run `sudo fanctl set ...`.

let base = URL(string: "http://127.0.0.1:8765")!

func http(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (Int, Any?)? {
    var req = URLRequest(url: base.appendingPathComponent(path))
    req.httpMethod = method
    if let b = body { req.httpBody = try? JSONSerialization.data(withJSONObject: b); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    var out: (Int, Any?)? = nil
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        out = (code, obj); sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 8)
    return out
}

func pretty(_ o: Any?) {
    guard let o else { print("(no response)"); return }
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) } else { print(o) }
}

func directStatus() {
    do {
        let fc = try FanControl()
        print("model \(SMCConnection.hardwareModel())  modeKey=\(fc.hw.modeKeyFormat) ftst=\(fc.hw.ftstAvailable)")
        for f in fc.allFans() {
            print("fan\(f.index): actual=\(Int(f.actualRPM)) target=\(Int(f.targetRPM)) range=[\(Int(f.minRPM))-\(Int(f.maxRPM))] mode=\(f.mode)")
        }
        for t in fc.temperatures(limit: 60).prefix(12) { print(String(format: "  %@ %.1f°C", t.key, t.celsius)) }
    } catch { print("SMC error: \(error)") }
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "status"

switch cmd {
case "status":
    if let (c, o) = http("GET", "/status"), c == 200 { pretty(o) }
    else { print("(daemon unreachable — direct SMC read)"); directStatus() }
case "sensors":
    if let (c, o) = http("GET", "/sensors"), c == 200 { pretty(o) }
    else {
        do {
            let fc = try FanControl()
            for t in fc.temperatures().prefix(40) { print(String(format: "%@ %.1f", t.key, t.celsius)) }
        } catch { print("SMC error: \(error)") }
    }
case "set":
    // usage: fanctl set <rpm|percent%> [--fan N] [--ttl seconds]
    guard args.count > 2 else { print("usage: fanctl set <rpm|80%> [--fan N] [--ttl seconds]"); exit(1) }
    var body: [String: Any] = [:]
    let v = args[2]
    if v.hasSuffix("%") { body["percent"] = Double(v.dropLast()) ?? 70 }
    else { body["rpm"] = Double(v) ?? 4500 }
    if let i = args.firstIndex(of: "--fan"), i + 1 < args.count { body["fan"] = Int(args[i+1]) ?? 0 }
    if let i = args.firstIndex(of: "--ttl"), i + 1 < args.count { body["ttl_seconds"] = Double(args[i+1]) ?? 900 }
    if let (c, o) = http("POST", "/set", body), c == 200 { pretty(o) }
    else {
        // direct (needs root)
        do {
            let fc = try FanControl()
            let fan = body["fan"] as? Int ?? 0
            var rpm: Float
            if let p = body["percent"] as? Double, let info = fc.readFan(fan) {
                rpm = info.minRPM + (info.maxRPM - info.minRPM) * Float(p) / 100
            } else { rpm = Float(body["rpm"] as? Double ?? 4500) }
            try fc.enableManual(fan: fan); try fc.setTarget(fan: fan, rpm: rpm)
            print("fan\(fan) -> \(Int(rpm)) RPM (direct, no TTL safety — prefer fand)")
        } catch { print("direct write failed (\(error)). Tip: sudo fanctl set … or run fand."); exit(1) }
    }
case "boost":
    if let (c, o) = http("POST", "/boost", ["ttl_seconds": 600]), c == 200 { pretty(o) }
    else { print("daemon unreachable; use: sudo fanctl set 100% --ttl 600") }
case "auto":
    var body: [String: Any] = [:]
    if let i = args.firstIndex(of: "--fan"), i + 1 < args.count { body["fan"] = Int(args[i+1]) ?? 0 }
    if let (c, o) = http("POST", "/auto", body), c == 200 { pretty(o) }
    else {
        do {
            let fc = try FanControl()
            if let f = body["fan"] as? Int { try fc.setAuto(fan: f) }
            else { for ff in fc.allFans() { try fc.setAuto(fan: ff.index) }; try fc.releaseUnlockIfNeeded() }
            print("auto restored (direct)")
        } catch { print("failed: \(error)"); exit(1) }
    }
default:
    print("""
    usage: fanctl <status|sensors|set|boost|auto>
      status                  fans + top temps (via daemon, else direct)
      sensors                 all temp sensors
      set <rpm|80%> [--fan N] [--ttl s]   manual speed (default TTL 15 min via daemon)
      boost                   all fans to max for 10 min
      auto [--fan N]          back to macOS control
    """)
}
