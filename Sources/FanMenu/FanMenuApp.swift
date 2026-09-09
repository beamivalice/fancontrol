import SwiftUI
import SMCCore

// FanMenu: mini menubar app. Talks to fand (127.0.0.1:8765); falls back to direct SMC reads.
// Run: swift run FanMenu  (lives in menu bar, no dock icon via LSUIElement when bundled)

@main
struct FanMenuApp: App {
    @StateObject private var model = FanModel()
    var body: some Scene {
        MenuBarExtra {
            FanMenuView(model: model)
        } label: {
            Label(model.title, systemImage: "fan")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class FanModel: ObservableObject {
    @Published var title = "— rpm"
    @Published var statusText = "connecting…"
    @Published var fans: [FanInfo] = []
    @Published var manual = false
    @Published var ttl: TimeInterval = 0
    @Published var percent: Double = 60
    @Published var daemonUp = false
    private var timer: Timer?

    init() { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { await self?.refresh() } }; Task { await refresh() } }

    func refresh() async {
        if let s = await api("GET", "/status") {
            daemonUp = true
            let fanDicts: [[String: Any]] = s["fans"] as? [[String: Any]] ?? []
            fans = fanDicts.compactMap { d -> FanInfo? in
                guard let i = d["index"] as? Int else { return nil }
                return FanInfo(index: i, actualRPM: (d["actualRPM"] as? Double).map(Float.init) ?? 0,
                               targetRPM: (d["targetRPM"] as? Double).map(Float.init) ?? 0,
                               minRPM: (d["minRPM"] as? Double).map(Float.init) ?? 0,
                               maxRPM: (d["maxRPM"] as? Double).map(Float.init) ?? 0,
                               mode: (d["mode"] as? Int) ?? -1)
            }
            if let c = s["control"] as? [String: Any] { manual = (c["manual"] as? Bool) ?? false; ttl = (c["ttlRemaining"] as? Double) ?? 0 }
            let rpms = fans.map { Int($0.actualRPM) }
            title = rpms.map(String.init).joined(separator: "/") + " rpm"
            let top = ((s["topTemps"] as? [[String: Any]])?.prefix(3) ?? []).map { "\($0["key"] ?? "?") \(Int(($0["celsius"] as? Double) ?? 0))°" }.joined(separator: "  ")
            statusText = manual ? "Manual · TTL \(Int(ttl))s · \(top)" : "Auto · \(top)"
        } else {
            daemonUp = false
            await readDirect()
        }
    }

    func readDirect() async {
        let data: [FanInfo]? = await Task.detached {
            (try? FanControl()).map { $0.allFans() }
        }.value
        guard let data else { statusText = "fand down · SMC unreadable"; return }
        fans = data
        title = data.map { String(Int($0.actualRPM)) }.joined(separator: "/") + " rpm"
        statusText = "fand down · direct read only (start fand for control)"
    }

    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765\(path)")!)
        req.httpMethod = method
        if let b = body { req.httpBody = try? JSONSerialization.data(withJSONObject: b); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        } catch { return nil }
    }

    func setPercent(_ p: Double) async { _ = await api("POST", "/set", ["percent": p, "ttl_seconds": 900]); await refresh() }
    func boost() async { _ = await api("POST", "/boost", ["ttl_seconds": 600]); await refresh() }
    func auto() async { _ = await api("POST", "/auto", [:]); await refresh() }
}

struct FanMenuView: View {
    @ObservedObject var model: FanModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fan Control").font(.headline)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            if !model.daemonUp {
                Text("Start the daemon for control:\n  sudo .build/debug/fand &").font(.caption).foregroundStyle(.orange)
            }
            ForEach(model.fans, id: \.index) { f in
                HStack { Text("Fan \(f.index)").font(.caption); Spacer(); Text("\(Int(f.actualRPM)) rpm → \(Int(f.targetRPM))").font(.caption.monospacedDigit()) }
                Text("mode \(f.mode == 0 ? "auto" : f.mode == 1 ? "manual" : f.mode == 3 ? "system" : "?") · range \(Int(f.minRPM))–\(Int(f.maxRPM))").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Manual").font(.caption)
                Slider(value: $model.percent, in: 30...100, step: 5)
                Text("\(Int(model.percent))%").font(.caption.monospacedDigit()).frame(width: 44)
            }
            HStack {
                Button("Set") { Task { await model.setPercent(model.percent) } }.disabled(!model.daemonUp)
                Button("Boost") { Task { await model.boost() } }.disabled(!model.daemonUp)
                Button("Auto") { Task { await model.auto() } }.disabled(!model.daemonUp)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.buttonStyle(.link)
            Text("Agents: curl localhost:8765/status · fanctl · MCP (see mcp/)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 300)
    }
}
