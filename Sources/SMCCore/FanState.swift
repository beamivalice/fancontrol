import Foundation

/// Observed fan state, shared by the menubar, `fanctl`, `/status` and MCP.
/// Never a command: nothing in this stack can put a fan into `.off`.
public enum FanState: String, Codable, Sendable {
    /// Nothing spinning. Idle-normal, but a fault while holding Max — so it outranks `.max`.
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

    /// `manual` is "we are holding Max": the daemon's TTL state, or the app's
    /// optimistic flag while a request is in flight.
    public static func state(fans: [FanInfo], manual: Bool) -> FanState {
        guard !fans.isEmpty else { return .unknown }
        if allStopped(fans) { return .off }
        return manual ? .max : .auto
    }
}
