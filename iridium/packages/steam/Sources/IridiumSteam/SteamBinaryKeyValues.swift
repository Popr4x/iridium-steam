import Foundation

/// A minimal parser for Valve's binary "KeyValues" (VDF) format, used to decode PICS appinfo
/// and package-info buffers. Format: a byte type tag, a null-terminated key, then a
/// type-specific value, recursively, terminated by a `0x08` End-of-object byte.
public indirect enum SteamKeyValue: Sendable {
    case dict([String: SteamKeyValue])
    case string(String)
    case int32(Int32)
    case uint64(UInt64)
    case float32(Float)

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .int32(value): String(value)
        case let .uint64(value): String(value)
        default: nil
        }
    }
    public var intValue: Int? {
        switch self {
        case let .int32(value): Int(value)
        case let .uint64(value): Int(value)
        case let .string(value): Int(value)
        default: nil
        }
    }
    public subscript(key: String) -> SteamKeyValue? {
        if case let .dict(map) = self { return map[key] }
        return nil
    }
}

enum SteamBinaryKeyValuesError: Error {
    case malformed
    case unsupportedAppInfoFormat(magic: UInt32)
}

enum SteamBinaryKeyValues {
    private enum NodeType: UInt8 {
        case dict = 0x00
        case string = 0x01
        case int32 = 0x02
        case float32 = 0x03
        case pointer = 0x04
        case wideString = 0x05
        case color = 0x06
        case uint64 = 0x07
        case end = 0x08
        case int64 = 0x0A
        case endOfBinary = 0x0B
    }

    /// Parses a single root object starting at `offset`. Returns the value and the offset
    /// just past it. Several PICS appinfo buffers are preceded by a small fixed header
    /// (e.g. universe/state u32s) that the caller should skip before calling this.
    static func parse(_ data: Data, offset: Int = 0) throws -> (SteamKeyValue, Int) {
        var index = offset
        return try parseObject(data, &index)
    }

    /// Parses a `CMsgClientPICSProductInfoResponse.AppInfo.buffer`. Steam's appinfo buffer is
    /// prefixed with a 4-byte magic; `0x0656_4433` is the classic inline-string binary VDF this
    /// parser supports. Newer `0x0756_4433`/`0x0556_4433` variants use a deduplicated trailing
    /// string table and are not decoded here.
    static func parseAppInfoBuffer(_ data: Data) throws -> SteamKeyValue {
        guard data.count > 8 else { throw SteamBinaryKeyValuesError.malformed }
        let magic = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard magic == 0x0656_4433 else {
            throw SteamBinaryKeyValuesError.unsupportedAppInfoFormat(magic: magic)
        }
        // magic(4) + universe(4) precede the KeyValues tree.
        let (value, _) = try parse(data, offset: 8)
        return value
    }

    private static func parseObject(_ data: Data, _ index: inout Int) throws -> (SteamKeyValue, Int) {
        var map: [String: SteamKeyValue] = [:]
        while true {
            guard index < data.count else { throw SteamBinaryKeyValuesError.malformed }
            let typeByte = data[data.startIndex + index]
            index += 1
            guard let type = NodeType(rawValue: typeByte) else { throw SteamBinaryKeyValuesError.malformed }
            if type == .end || type == .endOfBinary { break }
            let key = try readCString(data, &index)
            switch type {
            case .dict:
                let (child, _) = try parseObject(data, &index)
                map[key] = child
            case .string:
                map[key] = .string(try readCString(data, &index))
            case .int32, .color, .pointer:
                map[key] = .int32(try readInt32(data, &index))
            case .float32:
                map[key] = .float32(try readFloat32(data, &index))
            case .uint64, .int64:
                map[key] = .uint64(try readUInt64(data, &index))
            case .wideString:
                throw SteamBinaryKeyValuesError.malformed
            case .end, .endOfBinary:
                break
            }
        }
        return (.dict(map), index)
    }

    private static func readCString(_ data: Data, _ index: inout Int) throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard index < data.count else { throw SteamBinaryKeyValuesError.malformed }
            let byte = data[data.startIndex + index]
            index += 1
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readInt32(_ data: Data, _ index: inout Int) throws -> Int32 {
        guard index + 4 <= data.count else { throw SteamBinaryKeyValuesError.malformed }
        let start = data.startIndex + index
        let value = data.subdata(in: start..<(start + 4)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        index += 4
        return value
    }

    private static func readFloat32(_ data: Data, _ index: inout Int) throws -> Float {
        guard index + 4 <= data.count else { throw SteamBinaryKeyValuesError.malformed }
        let start = data.startIndex + index
        let bits = data.subdata(in: start..<(start + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        index += 4
        return Float(bitPattern: bits)
    }

    private static func readUInt64(_ data: Data, _ index: inout Int) throws -> UInt64 {
        guard index + 8 <= data.count else { throw SteamBinaryKeyValuesError.malformed }
        let start = data.startIndex + index
        let value = data.subdata(in: start..<(start + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        index += 8
        return value
    }
}
