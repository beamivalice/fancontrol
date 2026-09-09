import AppKit
import ServiceManagement
import SwiftUI
import SMCCore

// AppKit status item — SwiftUI MenuBarExtra cannot draw a two-line iStat widget.
// Bar: FAN / 12%   or   FAN / MAX. RPM only in the click popover.

@main
enum FanMenuMain {
    static var keep: AppDelegate?
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        keep = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = FanModel()
    var item: NSStatusItem!
    var glyph: TwoLineStatusView!
    var panel: NSPanel?
    var clickMonitor: Any?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: 30)
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp])
            glyph = TwoLineStatusView(frame: button.bounds)
            glyph.autoresizingMask = [.width, .height]
            glyph.wantsLayer = true
            button.addSubview(glyph)
        }

        model.onUpdate = { [weak self] in self?.paint() }
        Task {
            await self.model.refresh()
            if await self.model.helperOutdatedOrDown() { await self.model.ensureHelper() }
            self.paint()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.model.refresh()
                self.paint()
            }
        }
    }

    func paint() {
        glyph.top = model.topLine
        glyph.bottom = model.bottomLine
        glyph.needsDisplay = true
        item.button?.toolTip = model.manual ? "Fans at MAX — click for RPM" : "Auto — click for RPM"
    }

    @objc func toggle(_ sender: Any?) {
        if panel?.isVisible == true { closePanel(); return }
        guard let button = item.button, let buttonWindow = button.window else { return }

        let size = NSSize(width: 220, height: 236)
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        var origin = NSPoint(
            x: screenRect.midX - size.width / 2,
            y: screenRect.minY - size.height - 4
        )
        if let screen = buttonWindow.screen ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 6),
                           screen.visibleFrame.maxX - size.width - 6)
        }

        let host = NSHostingController(rootView: FanPopover(model: model))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.white.cgColor
        host.view.appearance = NSAppearance(named: .aqua)

        let win = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.appearance = NSAppearance(named: .aqua)
        win.contentViewController = host
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.backgroundColor = NSColor.white.cgColor
        win.contentView?.layer?.cornerRadius = 8
        win.contentView?.layer?.masksToBounds = true
        win.orderFrontRegardless()
        panel = win

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    func closePanel() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Draws into the live status-item button so text is retina and sits
/// in the same optical box as iStat CPU/GPU/RAM.
final class TwoLineStatusView: NSView {
    var top = "FAN"
    var bottom = "—"

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the button

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let color = NSColor.labelColor
        let topFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let botFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

        let topH: CGFloat = 9
        let botH: CGFloat = 12
        let stack = topH + botH - 1
        let y = ((bounds.height - stack) / 2).rounded(.toNearestOrAwayFromZero)

        (top as NSString).draw(
            in: NSRect(x: 0, y: y, width: bounds.width, height: topH),
            withAttributes: [.font: topFont, .foregroundColor: color, .paragraphStyle: style]
        )
        (bottom as NSString).draw(
            in: NSRect(x: 0, y: y + topH - 1, width: bounds.width, height: botH),
            withAttributes: [.font: botFont, .foregroundColor: color, .paragraphStyle: style]
        )
    }
}

@MainActor
final class FanModel: ObservableObject {
    @Published var topLine = "FAN"
    @Published var bottomLine = "—"
    @Published var fans: [FanInfo] = []
    @Published var manual = false
    @Published var ttl: TimeInterval = 0
    @Published var packageC: Int? = nil
    @Published var daemonUp = false
    @Published var openAtLogin = (SMAppService.mainApp.status == .enabled)
    /// App version from the bundle (CFBundleShortVersionString), shown in the popover title.
    let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    /// fand's `daemonAPIVersion`, nil while the helper is unreachable.
    @Published var helperVersion: Int? = nil
    var onUpdate: (() -> Void)?
    /// Must match fand `daemonAPIVersion`. Missing/old helpers get replaced.
    static let requiredHelperVersion = 3
    /// While a Max/Auto request is in flight, the 2s poll must not overwrite the icon.
    private enum Pending { case none, max, auto }
    private var pending: Pending = .none

    /// JSONSerialization turns whole numbers into Int, so `as? Double` misses them.
    static func number(_ raw: Any?) -> Float? {
        switch raw {
        case let v as Float: return v
        case let v as Double: return Float(v)
        case let v as Int: return Float(v)
        case let v as Int64: return Float(v)
        case let v as NSNumber: return v.floatValue
        default: return nil
        }
    }

    /// Per-fan: this fan's RPM over the machine's highest max (5777 on this M5).
    /// So the floor reads ~1350/5777 ≈ 23%, not “2% above min.”
    static func percent(of f: FanInfo, ceiling: Float) -> Int {
        guard ceiling > 0 else { return 0 }
        return Swift.max(0, Swift.min(100, Int((f.actualRPM / ceiling * 100).rounded())))
    }

    var ceilingRPM: Float { fans.map(\.maxRPM).max() ?? 0 }

    var glancePercent: Int {
        guard let top = fans.max(by: { $0.actualRPM < $1.actualRPM }) else { return 0 }
        return Self.percent(of: top, ceiling: ceilingRPM)
    }

    func refresh() async {
        if let s = await api("GET", "/status") {
            daemonUp = true
            apply(status: s)
        } else {
            daemonUp = false
            helperVersion = nil
            await readDirect()
        }
        updateTitle()
        onUpdate?()
    }

    func apply(status s: [String: Any]) {
        let fanDicts: [[String: Any]] = s["fans"] as? [[String: Any]] ?? []
        fans = fanDicts.compactMap { d -> FanInfo? in
            guard let i = Self.number(d["index"]).map(Int.init) else { return nil }
            return FanInfo(index: i, actualRPM: Self.number(d["actualRPM"]) ?? 0,
                           targetRPM: Self.number(d["targetRPM"]) ?? 0,
                           minRPM: Self.number(d["minRPM"]) ?? 0,
                           maxRPM: Self.number(d["maxRPM"]) ?? 0,
                           mode: Self.number(d["mode"]).map(Int.init) ?? -1)
        }
        if let c = s["control"] as? [String: Any] {
            ttl = Self.number(c["ttlRemaining"]).map { TimeInterval($0) } ?? 0
        }
        helperVersion = Self.number(s["version"]).map { Int($0) }
        let hardwareManual = fans.contains { $0.mode == 1 }
        switch pending {
        case .max: manual = true
        case .auto: manual = false; ttl = 0
        case .none: manual = hardwareManual
        }
        packageC = Self.packageTemp(from: s["topTemps"] as? [[String: Any]] ?? [])
    }

    /// Prefer the SoC package key. Never use Tf* (those include 99°C trip-point keys).
    static func packageTemp(from temps: [[String: Any]]) -> Int? {
        func c(_ d: [String: Any]) -> Double? { number(d["celsius"]).map(Double.init) }
        if let t = temps.first(where: { ($0["key"] as? String) == "TCMb" }), let v = c(t) { return Int(v) }
        let live = temps.compactMap { d -> (String, Double)? in
            guard let k = d["key"] as? String, let v = c(d) else { return nil }
            if k.hasPrefix("Tf") { return nil }
            if k.hasPrefix("TC") || k.hasPrefix("Tp") { return (k, v) }
            return nil
        }
        return live.max(by: { $0.1 < $1.1 }).map { Int($0.1) }
    }

    func updateTitle() {
        topLine = "FAN"
        if manual { bottomLine = "MAX" }
        else if !fans.isEmpty { bottomLine = "\(glancePercent)%" }
        else { bottomLine = "—" }
    }

    func readDirect() async {
        let data: [FanInfo]? = await Task.detached { (try? FanControl()).map { $0.allFans() } }.value
        fans = data ?? []
        if pending == .none { manual = fans.contains { $0.mode == 1 } }
        packageC = nil
    }

    func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 12
        if let b = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        } catch { return nil }
    }

    func max() async {
        pending = .max
        manual = true
        updateTitle()
        onUpdate?()
        if await api("POST", "/max", ["ttl_seconds": 900]) == nil {
            _ = await api("POST", "/boost", ["ttl_seconds": 900])
        }
        pending = .none
        await refresh()
    }

    func helperOutdatedOrDown() async -> Bool {
        guard let s = await api("GET", "/status") else { return true }
        let v = Self.number(s["version"]).map { Int($0) } ?? 0
        return v < Self.requiredHelperVersion
    }

    /// Prompt once for admin and install/replace the LaunchDaemon helper.
    /// After that launchd keeps it running at boot — the app does not sudo again.
    func ensureHelper() async {
        guard let script = Bundle.main.url(forResource: "install-fand", withExtension: "sh")?.path else { return }
        let bundle = Bundle.main.bundlePath
        let src = """
        set s to quoted form of "\(Self.appleEscape(script))"
        set b to quoted form of "\(Self.appleEscape(bundle))"
        do shell script (s & " " & b) with administrator privileges
        """
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        guard err == nil else { return }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await api("GET", "/status") != nil, !(await helperOutdatedOrDown()) {
                daemonUp = true
                await refresh()
                return
            }
        }
    }

    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    func auto() async {
        pending = .auto
        manual = false
        ttl = 0
        updateTitle()
        onUpdate?()
        _ = await api("POST", "/auto", [:])
        pending = .none
        await refresh()
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

struct FanPopover: View {
    @ObservedObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(model.manual ? "MAX" : "AUTO")
                    .font(.system(size: 13, weight: .semibold))
                Text("v\(model.appVersion)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let c = model.packageC {
                    Text("\(c)°C").font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            }

            if !model.daemonUp {
                Text("Helper not running").font(.caption).foregroundStyle(.secondary)
                Button("Install helper…") { Task { await model.ensureHelper() } }
                    .font(.caption)
            } else if let h = model.helperVersion, h < FanModel.requiredHelperVersion {
                Text("Helper v\(h) is older than this app (needs v\(FanModel.requiredHelperVersion))").font(.caption).foregroundStyle(.orange)
                Button("Update helper…") { Task { await model.ensureHelper() } }
                    .font(.caption)
            } else if model.manual, model.ttl > 0 {
                Text("Auto in \(Int(model.ttl / 60))m").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.fans, id: \.index) { f in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Fan \(f.index + 1)").font(.caption)
                        Spacer()
                        Text("\(Int(f.actualRPM)) rpm · \(FanModel.percent(of: f, ceiling: model.ceilingRPM))%")
                            .font(.caption.monospacedDigit())
                    }
                    Text("min \(Int(f.minRPM)) · max \(Int(f.maxRPM))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Open at Login", isOn: Binding(
                get: { model.openAtLogin },
                set: { model.setOpenAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            HStack(spacing: 8) {
                Button("Auto") { Task { await model.auto() } }
                    .disabled(!model.daemonUp || !model.manual)
                    .keyboardShortcut("a")
                Button("Max") { Task { await model.max() } }
                    .disabled(!model.daemonUp || model.manual)
                    .keyboardShortcut("m")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    // Never tint this secondary: the panel is a nonactivating
                    // window, so dimmed text reads as "disabled" even though the
                    // button always works. Keep it at full label strength.
                    .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(Color.white)
        .preferredColorScheme(.light)
    }
}
