import Foundation
import SMCCore

// fanctl: CLI for humans + scripts + agents. SAFE SUBSET ONLY: Auto and Max.
// Prefers the fand HTTP API (127.0.0.1:8765); falls back to direct SMC reads.
// Direct Max writes require root: `sudo fanctl max`.

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
    _ = sem.wait(timeout: .now() + 30)
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

func ttlFromArgs(_ args: [String]) -> Double {
    if let i = args.firstIndex(of: "--ttl"), i + 1 < args.count { return Double(args[i+1]) ?? 900 }
    return 900
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
case "max", "boost":
    // usage: fanctl max [--ttl seconds]  (boost = alias)
    let ttl = ttlFromArgs(args)
    if let (c, o) = http("POST", "/max", ["ttl_seconds": ttl]), c == 200 { pretty(o) }
    else {
        do {
            let fc = try FanControl()
            try fc.setAllMax()
            print("all fans -> MAX (direct, no TTL safety — prefer fand)")
            directStatus()
        } catch { print("direct write failed (\(error)). Tip: sudo fanctl max, or start fand."); exit(1) }
    }
case "auto":
    if let (c, o) = http("POST", "/auto", [:]), c == 200 { pretty(o) }
    else {
        do {
            let fc = try FanControl()
            try fc.setAllAuto()
            print("auto restored (direct)")
        } catch { print("failed: \(error)"); exit(1) }
    }
default:
    print("""
    usage: fanctl <status|sensors|max|auto>
      status    fans + top temps (via daemon, else direct)
      sensors   all temp sensors
      max       all fans to MAX [--ttl s] (default 15 min via daemon, then auto)
      boost     alias for max
      auto      back to macOS control (the default)
    Only Max and Auto exist — no low/custom speed is expressible.
    """)
}
