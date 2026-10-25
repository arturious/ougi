import IOKit
import Foundation

// AppleSMC user client structures (layout matches the kernel's SMCParamStruct, 80 bytes).
struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
struct SMCKeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCError: Error, CustomStringConvertible {
    case open(kern_return_t), call(kern_return_t), result(UInt8), badType(String)
    var description: String {
        switch self {
        case .open(let r): return "cannot open AppleSMC (\(r))"
        case .call(let r): return "SMC call failed (\(r))"
        case .result(let r): return "SMC returned error \(r)"
        case .badType(let t): return "unexpected SMC type \(t)"
        }
    }
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func fourCCString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    init() throws {
        var service: io_service_t = 0
        for name in ["AppleSMC", "AppleSMCKeysEndpoint"] where service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        }
        guard service != 0 else { throw SMCError.open(kIOReturnNotFound) }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.open(r) }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCParam) throws -> SMCParam {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        guard r == kIOReturnSuccess else { throw SMCError.call(r) }
        guard output.result == 0 else { throw SMCError.result(output.result) }
        return output
    }

    func keyCount() throws -> Int {
        let (_, bytes) = try read("#KEY")
        return bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    func key(at index: Int) throws -> String {
        var p = SMCParam()
        p.data8 = 8 // kSMCGetKeyFromIndex
        p.data32 = UInt32(index)
        return fourCCString(try call(&p).key)
    }

    func info(_ key: String) throws -> SMCKeyInfo {
        let k = fourCC(key)
        if let cached = infoCache[k] { return cached }
        var p = SMCParam()
        p.key = k
        p.data8 = 9 // kSMCGetKeyInfo
        let info = try call(&p).keyInfo
        infoCache[k] = info
        return info
    }

    func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let info = try info(key)
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = info.dataSize
        p.data8 = 5 // kSMCReadKey
        let out = try call(&p)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (fourCCString(info.dataType), bytes)
    }

    func write(_ key: String, _ bytes: [UInt8]) throws {
        let info = try info(key)
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = info.dataSize
        p.data8 = 6 // kSMCWriteKey
        withUnsafeMutableBytes(of: &p.bytes) { buf in
            for (i, b) in bytes.prefix(Int(info.dataSize)).enumerated() { buf[i] = b }
        }
        _ = try call(&p)
    }

    // Numeric reading of the common SMC types.
    func number(_ key: String) throws -> Double {
        let (type, b) = try read(key)
        switch type {
        case "flt ": return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78": return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2": return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        default: throw SMCError.badType(type)
        }
    }

    func writeNumber(_ key: String, _ value: Double) throws {
        let (type, _) = try read(key)
        switch type {
        case "flt ": try write(key, withUnsafeBytes(of: Float32(value)) { Array($0) })
        case "ui8 ": try write(key, [UInt8(clamping: Int(value))])
        case "fpe2":
            let v = UInt16(clamping: Int(value * 4))
            try write(key, [UInt8(v >> 8), UInt8(v & 0xff)])
        default: throw SMCError.badType(type)
        }
    }
}
