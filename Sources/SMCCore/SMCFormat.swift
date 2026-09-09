import Foundation

/// SMC data-format conversions.
/// - Integers (ui8/ui16/ui32) and fixed-point (fpe2/sp78): big-endian per SMC protocol.
/// - Floats (flt, Apple Silicon fan RPM): native little-endian IEEE 754.
/// - Size disambiguates fan RPM: 4 bytes = flt (AS), 2 bytes = fpe2 (Intel).
public enum SMCFormat {
    public static func float(from bytes: [UInt8], size: UInt32) -> Float {
        if size == 4, bytes.count >= 4 {
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }
        if bytes.count >= 2 { return Float(uint16(from: bytes)) / 4.0 }
        return 0
    }

    public static func bytes(from value: Float, size: UInt32) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: Int(size))
        if size == 4 {
            withUnsafeBytes(of: value) { b in for i in 0..<4 { r[i] = b[i] } }
        } else {
            let raw = UInt16(max(0, value * 4.0))
            r[0] = UInt8(raw >> 8); r[1] = UInt8(raw & 0xFF)
        }
        return r
    }

    /// sp78: signed 7.8 fixed point (Intel temps), big-endian.
    public static func sp78(from bytes: [UInt8]) -> Float {
        guard bytes.count >= 2 else { return 0 }
        let raw = Int16(bitPattern: uint16(from: bytes))
        return Float(raw) / 256.0
    }

    public static func uint8(from bytes: [UInt8]) -> UInt8 { bytes.first ?? 0 }

    public static func uint16(from bytes: [UInt8]) -> UInt16 {
        guard bytes.count >= 2 else { return 0 }
        return bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    public static func uint32(from bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 4 else { return 0 }
        return bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
    }
}
