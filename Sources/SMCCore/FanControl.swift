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
public final class FanControl: @unchecked Sendable {
    public let conn: SMCConnection
    public let hw: HardwareConfig

    public init(connection: SMCConnection? = nil) throws {
        self.conn = try connection ?? SMCConnection()
        self.hw = HardwareConfig.detect(connection: conn)
    }

    public var fanCount: Int {
        guard let (b, _) = try? conn.readKey(FanKey.count) else { return 0 }
        return Int(SMCFormat.uint8(from: b))
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

    /// One fan to its hardware maximum: manual mode, then max target.
    public func setMax(fan: Int) throws {
        guard let info = readFan(fan) else { throw SMCError.firmware(.notFound) }
        try enableManual(fan: fan)
        try writeTarget(fan: fan, rpm: info.maxRPM)
    }

    public func setAllMax() throws {
        for f in 0..<fanCount { try setMax(fan: f) }
    }

    public func setAuto(fan: Int) throws {
        try conn.writeKey(FanKey.key(hw.modeKeyFormat, fan: fan), bytes: [0])
    }

    public func setAllAuto() throws {
        for f in 0..<fanCount { try setAuto(fan: f) }
        try releaseUnlockIfNeeded()
    }

    // MARK: - Writes

    /// M1/M2/M5 accept a direct write; M3/M4 need an `Ftst` unlock and retry.
    private func enableManual(fan: Int) throws {
        let modeKey = FanKey.key(hw.modeKeyFormat, fan: fan)
        do {
            try conn.writeKey(modeKey, bytes: [1])
            return
        } catch {
            guard hw.ftstAvailable else { throw error }
        }
        try conn.writeKey(FanKey.forceTest, bytes: [1])
        Thread.sleep(forTimeInterval: 0.5)
        let deadline = Date().addingTimeInterval(10)
        while true {
            do { try conn.writeKey(modeKey, bytes: [1]); return }
            catch {
                if Date() >= deadline { throw SMCError.timeout }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
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

    /// Cached SoC/package keys. `Tf*` are 99 °C trip points rather than live die
    /// temps, so they must never reach the failsafe.
    private var dieKeys: [String]?

    public func dieTemperatures() -> [(key: String, celsius: Float)] {
        let keys: [String]
        if let cached = dieKeys {
            keys = cached
        } else {
            keys = conn.enumerateKeys().filter { k in
                (k.hasPrefix("TC") || k.hasPrefix("Tp")) && !k.hasPrefix("Tf")
            }
            dieKeys = keys
        }
        return decodeTemps(keys)
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
