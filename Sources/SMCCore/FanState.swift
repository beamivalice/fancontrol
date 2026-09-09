import Foundation

/// Observed fan state, shared by the menubar, `fanctl`, `/status` and MCP.
/// Never a command: nothing in this stack can put a fan into `.off`.
public enum FanState: String, Codable, Sendable {
    /// Nothing spinning under Auto.
    case off
    case max
    case auto
    /// No reading at all. Not the same claim as `.off`, which reads zero.
    case unknown
}

public enum FanHealth {
    /// Stopped fans read 0, not the idle floor, so near-zero means stopped.
    public static let stoppedRPM: Float = 100
    /// Firmware floor used to kick a parked motor when `F%dMn` reads unusable.
    public static let idleFloorRPM: Float = 1350

    public static func allStopped(_ fans: [FanInfo]) -> Bool {
        !fans.isEmpty && fans.allSatisfy { $0.actualRPM < stoppedRPM }
    }

    /// Firmware / thermalmonitord drop manual mode when they park the fans.
    /// A Max hold must be written again until mode, target, and spin recover.
    public static func needsMaxReassert(_ fans: [FanInfo]) -> Bool {
        !fans.isEmpty && fans.contains { f in
            f.mode != 1
                || (f.maxRPM > 0 && f.targetRPM < f.maxRPM * 0.95)
                || f.actualRPM < stoppedRPM
        }
    }

    /// Max to command for a fan: live `F%dMx`, or the last good value when the
    /// firmware reads 0 for a parked fan. A 0 result means "never observed", and
    /// the caller must refuse rather than kick toward zero.
    public static func resolveMax(live: Float, lastGood: Float) -> Float {
        live > 0 ? live : lastGood
    }

    /// This fan's RPM over *its own* `F%dMx`.
    public static func percent(of f: FanInfo) -> Int {
        guard f.maxRPM > 0 else { return 0 }
        return Swift.max(0, Swift.min(100, Int((f.actualRPM / f.maxRPM * 100).rounded())))
    }

    /// `manual` is "we are holding Max": the daemon's TTL state, or the app's
    /// optimistic flag while a request is in flight.
    public static func state(fans: [FanInfo], manual: Bool) -> FanState {
        guard !fans.isEmpty else { return .unknown }
        if manual { return .max }
        if allStopped(fans) { return .off }
        return .auto
    }
}
