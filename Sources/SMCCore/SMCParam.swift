import Foundation

// MARK: - SMC protocol constants
// Based on VirtualSMC SDK (AppleSmc.h), Asahi Linux macsmc docs,
// and agoodkind/macos-smc-fan research (MIT). Implemented independently.

public enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

public enum SMCResultCode: UInt8, CustomStringConvertible, Sendable {
    case success = 0x00
    case error = 0x01
    case commCollision = 0x80
    case spuriousData = 0x81
    case badCommand = 0x82 // firmware rejects (e.g. mode write while in System mode)
    case badParameter = 0x83
    case notFound = 0x84
    case notReadable = 0x85
    case notWritable = 0x86
    case keySizeMismatch = 0x87
    case framingError = 0x88
    case badArgumentError = 0x89

    public var description: String {
        switch self {
        case .success: return "success"
        case .error: return "error"
        case .commCollision: return "commCollision"
        case .spuriousData: return "spuriousData"
        case .badCommand: return "badCommand(0x82)"
        case .badParameter: return "badParameter"
        case .notFound: return "notFound"
        case .notReadable: return "notReadable"
        case .notWritable: return "notWritable"
        case .keySizeMismatch: return "keySizeMismatch"
        case .framingError: return "framingError"
        case .badArgumentError: return "badArgumentError"
        }
    }
}

public enum SMCError: LocalizedError, Sendable {
    case connectionFailed
    case firmware(SMCResultCode)
    case ioKit(kern_return_t)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to open AppleSMC"
        case .timeout: return "SMC operation timed out"
        case .ioKit(let c): return String(format: "IOKit error 0x%x", c)
        case .firmware(let c): return "SMC firmware: \(c)"
        }
    }
}

/// 80-byte struct matching the AppleSMC kernel interface.
/// Offsets: keyInfo.dataSize @28, data8 @42. Must use stride (not size) in IOConnect call.
public struct SMCParamStruct {
    public typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    public struct Version { public var major: UInt8 = 0; public var minor: UInt8 = 0; public var build: UInt8 = 0; public var reserved: UInt8 = 0; public var release: UInt16 = 0; public init() {} }
    public struct PLimitData { public var version: UInt16 = 0; public var length: UInt16 = 0; public var cpuPLimit: UInt32 = 0; public var gpuPLimit: UInt32 = 0; public var memPLimit: UInt32 = 0; public init() {} }
    public struct KeyInfo { public var dataSize: UInt32 = 0; public var dataType: UInt32 = 0; public var dataAttributes: UInt8 = 0; public init() {} }

    public var key: UInt32 = 0
    public var vers = Version()
    public var pLimitData = PLimitData()
    public var keyInfo = KeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    public init() {}
}
