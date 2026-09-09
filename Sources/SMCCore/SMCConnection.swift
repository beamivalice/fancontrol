import Foundation
import IOKit

/// Thin wrapper around the AppleSMC IOKit service.
/// Reads work unprivileged. Writes to fan keys require root (firmware-enforced per key).
public final class SMCConnection: @unchecked Sendable {
    private let connection: io_connect_t

    public init() throws {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) { mainPort = kIOMainPortDefault }
        else { mainPort = kIOMasterPortDefault }
        guard IOServiceGetMatchingServices(mainPort, IOServiceMatching("AppleSMC"), &iterator) == kIOReturnSuccess else {
            throw SMCError.connectionFailed
        }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw SMCError.connectionFailed }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            throw SMCError.connectionFailed
        }
        self.connection = conn
    }

    deinit { IOServiceClose(connection) }

    public static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var m = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &m, &size, nil, 0)
        return String(bytes: m.prefix { $0 != 0 }.map { UInt8($0) }, encoding: .utf8) ?? ""
    }

    public func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
        let (param, output) = try fetchKeyInfo(key)
        var rp = param
        rp.keyInfo.dataSize = output.keyInfo.dataSize
        rp.data8 = SMCCommand.readBytes.rawValue
        let out = try callSMC(input: rp)
        let size = output.keyInfo.dataSize
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(size))) }
        return (bytes, size)
    }

    public func writeKey(_ key: String, bytes: [UInt8]) throws {
        let (param, output) = try fetchKeyInfo(key)
        var wp = param
        wp.data8 = SMCCommand.writeBytes.rawValue
        wp.keyInfo.dataSize = output.keyInfo.dataSize
        wp.bytes = bytesToTuple(bytes)
        let out = try callSMC(input: wp)
        if out.result != SMCResultCode.success.rawValue {
            // 0x87 keySizeMismatch sometimes still applies the value; tolerate for F%Tg
            if out.result == SMCResultCode.keySizeMismatch.rawValue, key.hasSuffix("Tg") { return }
            guard let code = SMCResultCode(rawValue: out.result) else { throw SMCError.firmware(.error) }
            throw SMCError.firmware(code)
        }
    }

    public func keyExists(_ key: String) -> Bool {
        (try? fetchKeyInfo(key)) != nil
    }

    public func fetchKeyInfo(_ key: String) throws -> (param: SMCParamStruct, output: SMCParamStruct) {
        var param = SMCParamStruct()
        param.key = try fourCharCode(from: key)
        param.data8 = SMCCommand.readKeyInfo.rawValue
        let output = try callSMC(input: param)
        guard output.result == SMCResultCode.success.rawValue,
              let _ = SMCResultCode(rawValue: output.result) else {
            guard let code = SMCResultCode(rawValue: output.result) else { throw SMCError.firmware(.error) }
            throw SMCError.firmware(code)
        }
        return (param, output)
    }

    public func callSMC(input: SMCParamStruct) throws -> SMCParamStruct {
        var inp = SMCParamStruct()
        inp.key = input.key
        inp.data8 = input.data8
        inp.data32 = input.data32
        inp.keyInfo.dataSize = input.keyInfo.dataSize
        inp.bytes = input.bytes
        var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(connection, UInt32(SMCCommand.kernelIndex.rawValue),
                                          &inp, MemoryLayout<SMCParamStruct>.stride, &out, &outSize)
        guard r == kIOReturnSuccess else { throw SMCError.ioKit(r) }
        return out
    }

    public func enumerateKeys() -> [String] {
        guard let (cb, cs) = try? readKey("#KEY"), cs >= 4 else { return [] }
        let total = SMCFormat.uint32(from: cb)
        var keys: [String] = []
        keys.reserveCapacity(Int(total))
        for i in 0..<total {
            var inp = SMCParamStruct()
            inp.data8 = SMCCommand.readIndex.rawValue
            inp.data32 = UInt32(i)
            guard let out = try? callSMC(input: inp) else { continue }
            let k = out.key
            keys.append(String(bytes: [UInt8((k >> 24) & 0xFF), UInt8((k >> 16) & 0xFF), UInt8((k >> 8) & 0xFF), UInt8(k & 0xFF)], encoding: .utf8) ?? "????")
        }
        return keys
    }

    func fourCharCode(from s: String) throws -> UInt32 {
        guard s.count == 4 else { throw SMCError.firmware(.badParameter) }
        return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func bytesToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes32 {
        var p = array + Array(repeating: 0, count: max(0, 32 - array.count))
        if p.count > 32 { p = Array(p.prefix(32)) }
        return (p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15],p[16],p[17],p[18],p[19],p[20],p[21],p[22],p[23],p[24],p[25],p[26],p[27],p[28],p[29],p[30],p[31])
    }
}
