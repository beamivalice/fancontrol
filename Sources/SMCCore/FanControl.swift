import Foundation

// MARK: - Fan key templates

public enum FanKey {
    public static let count = "FNum"
    public static let actual = "F%dAc"
    public static let target = "F%dTg"
    public static let minimum = "F%dMn"
    public static let maximum = "F%dMx"
    public static let forceTest = "Ftst"
    public static let modeLower = "F%dmd" // M5
    public static let modeUpper = "F%dMd" // M1–M4
    public static func key(_ template: String, fan: Int) -> String { String(format: template, fan) }
}

public struct FanInfo: Codable, Sendable {
    public var index: Int
    public var actualRPM: Float
    public var targetRPM: Float
    public var minRPM: Float
    public var maxRPM: Float
    /// 0=auto 1=manual 3=system(thermalmonitord). 2=legacy.
    public var mode: Int
    public init(index: Int, actualRPM: Float, targetRPM: Float, minRPM: Float, maxRPM: Float, mode: Int) {
        self.index = index; self.actualRPM = actualRPM; self.targetRPM = targetRPM
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.mode = mode
    }
}

public struct HardwareConfig: Sendable {
    public var modeKeyFormat: String
    public var ftstAvailable: Bool
    public static func detect(connection: SMCConnection) -> HardwareConfig {
        var mode = FanKey.modeLower
        for cand in [FanKey.modeLower, FanKey.modeUpper] {
            if connection.keyExists(FanKey.key(cand, fan: 0)) { mode = cand; break }
        }
        return HardwareConfig(modeKeyFormat: mode, ftstAvailable: connection.keyExists(FanKey.forceTest))
    }
}

/// Fan control. The only manual state is every fan at its hardware-reported
/// maximum (`F%dMx`); there is deliberately no API for a low or custom RPM.
///
/// Thread shape: reads touch only immutable state (or `cacheLock`), so the
/// thermal failsafe can never queue behind a fan write. Writes are one
/// transaction under `writeLock` — kick, target and mode must not interleave
/// with a second writer, which is what strands `mode=1` on a stale target.
public final class FanControl: @unchecked Sendable {
    public let conn: SMCConnection
    public let hw: HardwareConfig
    public let fanCount: Int
    /// Longest a single write transaction may hold `writeLock`. Kept under the
    /// menubar's 15 s request timeout so a slow Max cannot outlive its client.
    public let writeBudget: TimeInterval

    private let writeLock = NSLock()
    private let cacheLock = NSLock()
    private var lastKnownMax: [Int: Float] = [:]
    private var dieKeysCache: [String]?

    public init(connection: SMCConnection? = nil, writeBudget: TimeInterval = 8) throws {
        let opened = try connection ?? SMCConnection()
        self.conn = opened
        self.hw = HardwareConfig.detect(connection: opened)
        self.writeBudget = writeBudget
        if let (b, _) = try? opened.readKey(FanKey.count) { self.fanCount = Int(SMCFormat.uint8(from: b)) }
        else { self.fanCount = 0 }
    }

    public func readFan(_ i: Int) -> FanInfo? {
        guard
            let (ab, as_) = try? conn.readKey(FanKey.key(FanKey.actual, fan: i)),
            let (tb, ts) = try? conn.readKey(FanKey.key(FanKey.target, fan: i)),
            let (nb, ns) = try? conn.readKey(FanKey.key(FanKey.minimum, fan: i)),
            let (xb, xs) = try? conn.readKey(FanKey.key(FanKey.maximum, fan: i))
        else { return nil }
        let modeKey = FanKey.key(hw.modeKeyFormat, fan: i)
        let mode = (try? conn.readKey(modeKey)).map { Int(SMCFormat.uint8(from: $0.bytes)) } ?? -1
        return FanInfo(index: i,
                       actualRPM: SMCFormat.float(from: ab, size: as_),
                       targetRPM: SMCFormat.float(from: tb, size: ts),
                       minRPM: SMCFormat.float(from: nb, size: ns),
                       maxRPM: SMCFormat.float(from: xb, size: xs),
                       mode: mode)
    }

    public func allFans() -> [FanInfo] { (0..<fanCount).compactMap(readFan) }

    // MARK: - Write transactions

    /// One fan to its hardware maximum: manual mode, then max target.
    public func setMax(fan: Int) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let info = readFan(fan) else { throw SMCError.firmware(.notFound) }
        let rpm = resolvedMax(for: fan, from: info)
        guard rpm > 0 else { throw SMCError.firmware(.notFound) }
        let end = Date().addingTimeInterval(writeBudget)
        try kickIfParked(fan: fan, info: info, deadline: end)
        try enableManual(fan: fan, deadline: end)
        try writeTarget(fan: fan, rpm: rpm)
    }

    /// All fans to hardware maximum. Returns true only when every fan is
    /// confirmed manual at target; false means the monitor will keep
    /// re-asserting, not that the write failed.
    @discardableResult
    public func setAllMax() throws -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        let end = Date().addingTimeInterval(writeBudget)
        let n = fanCount
        guard n > 0 else { return false }
        var targets: [Int: Float] = [:]
        for f in 0..<n {
            guard let info = readFan(f) else { throw SMCError.firmware(.notFound) }
            let rpm = resolvedMax(for: f, from: info)
            guard rpm > 0 else { throw SMCError.firmware(.notFound) }
            targets[f] = rpm
        }
        // Firmware accepts F%dTg=max while parked at 0 rpm and never starts
        // the motor. Kick at the min floor first, then climb to max.
        try kickParkedFans(until: min(end, Date().addingTimeInterval(2.5)))
        var lastError: Error?
        while Date() < end {
            do {
                for f in 0..<n { try writeTarget(fan: f, rpm: targets[f]!) }
                let unlockBy = min(end, Date().addingTimeInterval(1.5))
                for f in 0..<n { try enableManual(fan: f, deadline: unlockBy) }
                Thread.sleep(forTimeInterval: 0.1)
                let fans = allFans()
                if fans.count == n, fans.allSatisfy({ f in
                    guard let want = targets[f.index], want > 0 else { return false }
                    return f.mode == 1 && f.targetRPM >= want * 0.95
                }) {
                    return true
                }
            } catch {
                lastError = error
            }
            if Date().addingTimeInterval(0.25) >= end { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        if let lastError { throw lastError }
        return false
    }

    /// Parked fans ignore a jump to max; start the motor at the firmware floor.
    /// Returns as soon as anything turns, or when `until` passes.
    private func kickParkedFans(until: Date) throws {
        let fans = allFans()
        guard fans.contains(where: { $0.actualRPM < FanHealth.stoppedRPM }) else { return }
        for f in fans {
            try kickIfParked(fan: f.index, info: f, deadline: until)
        }
        while Date() < until {
            if allFans().contains(where: { $0.actualRPM >= FanHealth.stoppedRPM }) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private func kickIfParked(fan: Int, info: FanInfo, deadline: Date) throws {
        guard info.actualRPM < FanHealth.stoppedRPM else { return }
        let kick = info.minRPM > FanHealth.stoppedRPM ? info.minRPM : FanHealth.idleFloorRPM
        try enableManual(fan: fan, deadline: deadline)
        try writeTarget(fan: fan, rpm: kick)
        try enableManual(fan: fan, deadline: deadline)
    }

    /// A parked fan can momentarily report `F%dMx` as 0; fall back to the last
    /// good maximum so a kick is never aimed at 0 rpm.
    private func resolvedMax(for fan: Int, from info: FanInfo) -> Float {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let rpm = FanHealth.resolveMax(live: info.maxRPM, lastGood: lastKnownMax[fan] ?? 0)
        if rpm > 0 { lastKnownMax[fan] = rpm }
        return rpm
    }

    public func setAuto(fan: Int) throws {
        try conn.writeKey(FanKey.key(hw.modeKeyFormat, fan: fan), bytes: [0])
    }

    public func setAllAuto() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        for f in 0..<fanCount { try setAuto(fan: f) }
        try releaseUnlockIfNeeded()
    }

    // MARK: - Writes

    /// M1/M2/M5 accept a direct write; M3/M4 need an `Ftst` unlock and retry
    /// until `deadline`. The budget is shared by the whole transaction so two
    /// fans can't cost twice the wait a client is already holding.
    private func enableManual(fan: Int, deadline: Date) throws {
        let modeKey = FanKey.key(hw.modeKeyFormat, fan: fan)
        do {
            try conn.writeKey(modeKey, bytes: [1])
            return
        } catch {
            guard hw.ftstAvailable else { throw error }
        }
        try conn.writeKey(FanKey.forceTest, bytes: [1])
        Thread.sleep(forTimeInterval: 0.5)
        while Date() < deadline {
            do { try conn.writeKey(modeKey, bytes: [1]); return }
            catch { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw SMCError.timeout
    }

    private func writeTarget(fan: Int, rpm: Float) throws {
        let key = FanKey.key(FanKey.target, fan: fan)
        let (_, size) = try conn.readKey(key)
        try conn.writeKey(key, bytes: SMCFormat.bytes(from: rpm, size: size))
    }

    /// Call after ALL fans are back to auto: releases Ftst if it was used.
    public func releaseUnlockIfNeeded() throws {
        guard hw.ftstAvailable,
              let (b, _) = try? conn.readKey(FanKey.forceTest),
              SMCFormat.uint8(from: b) == 1 else { return }
        try conn.writeKey(FanKey.forceTest, bytes: [0])
    }

    // MARK: Sensors

    /// SoC/package keys. `Tf*` are 99 °C trip points rather than live die temps,
    /// so they must never reach the failsafe. Enumerating the key set is
    /// expensive, so it is cached once behind `cacheLock`.
    private func dieKeys() -> [String] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = dieKeysCache { return cached }
        let keys = conn.enumerateKeys().filter { $0.hasPrefix("TC") || $0.hasPrefix("Tp") }
        dieKeysCache = keys
        return keys
    }

    public func dieTemperatures() -> [(key: String, celsius: Float)] {
        decodeTemps(dieKeys())
    }

    /// All plausible T* keys (for `fanctl sensors`). Includes non-die probes.
    public func temperatures(limit: Int = 400) -> [(key: String, celsius: Float)] {
        decodeTemps(Array(conn.enumerateKeys().filter { $0.hasPrefix("T") }.prefix(limit)))
    }

    private func decodeTemps(_ keys: [String]) -> [(key: String, celsius: Float)] {
        var out: [(String, Float)] = []
        for k in keys {
            guard let info = try? conn.fetchKeyInfo(k) else { continue }
            let rawType = withUnsafeBytes(of: info.output.keyInfo.dataType.bigEndian) {
                String(bytes: $0, encoding: .ascii) ?? ""
            }
            let type = rawType.trimmingCharacters(in: .whitespaces)
            guard let (bytes, size) = try? conn.readKey(k) else { continue }
            let c: Float
            switch type {
            case "flt": c = SMCFormat.float(from: bytes, size: size)
            case "sp78": c = SMCFormat.sp78(from: bytes)
            case "fpe2": c = Float(SMCFormat.uint16(from: bytes)) / 4.0
            default: continue
            }
            guard c.isFinite, c > -40, c < 115 else { continue }
            out.append((k, c))
        }
        return out.sorted { $0.1 > $1.1 }
    }
}
