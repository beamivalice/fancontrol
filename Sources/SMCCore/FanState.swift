import Foundation

/// Observed fan state, shared by the menubar, `fanctl`, `/status` and MCP.
/// Never a command: nothing in this stack can put a fan into `.off`.
public enum FanState: String, Codable, Sendable {
    /// Nothing spinning under Auto. A Max hold is `.max` even at 0 rpm — OFF
    /// used to outrank it and made the Max click look like a no-op.
    case off
    case max
    case auto
    /// No reading at all. Not the same claim as `.off`, which reads zero.
    case unknown
}

public enum FanHealth {
    /// Stopped fans read 0, not the ~1350 rpm idle floor, so near-zero means stopped.
    public static let stoppedRPM: Float = 100

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

    /// This fan's RPM over *its* F%dMx. Fan 1 at 5350 is 100%; the other at 5777 is 100%.
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
