import Foundation
import SwiftProtobuf

/// Subset of Steam's `EMsg` enum needed for login, licenses, PICS, and depot key exchange.
/// Values are taken from SteamKit's generated `SteamLanguage.cs` (public protocol constants).
enum SteamEMsg: Int32, Sendable {
    case invalid = 0
    case multi = 1
    case clientHeartBeat = 703
    case clientGamesPlayed = 742
    case clientLogOnResponse = 751
    case clientLoggedOff = 757
    case clientLicenseList = 780
    case channelEncryptRequest = 1303
    case channelEncryptResponse = 1304
    case channelEncryptResult = 1305
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case clientLogon = 5514
    case clientUpdateMachineAuth = 5537
    case clientGetCDNAuthToken = 5546
    case clientGetCDNAuthTokenResponse = 5547
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
}

enum SteamMsgUtil {
    static let protoMask: UInt32 = 0x8000_0000

    static func isProtoBuf(_ raw: UInt32) -> Bool { raw & protoMask != 0 }

    static func rawEMsg(_ msg: SteamEMsg) -> UInt32 { UInt32(bitPattern: msg.rawValue) }

    static func makeProtoMsg(_ msg: SteamEMsg) -> UInt32 { rawEMsg(msg) | protoMask }

    static func stripProtoFlag(_ raw: UInt32) -> Int32 { Int32(bitPattern: raw & ~protoMask) }
}

/// The plain (non-protobuf) 20-byte header used only for the three channel-encryption messages.
struct SteamPlainMsgHeader {
    var msg: SteamEMsg
    var targetJobID: UInt64 = .max
    var sourceJobID: UInt64 = .max

    func serialize() -> Data {
        var data = Data()
        data.append(littleEndian: UInt32(bitPattern: msg.rawValue))
        data.append(littleEndian: targetJobID)
        data.append(littleEndian: sourceJobID)
        return data
    }
}

/// A decoded incoming frame: either one of the three plain channel-encryption messages, or a
/// protobuf-framed client message with its header and raw body bytes.
enum SteamIncomingFrame {
    case plain(msg: SteamEMsg, payload: Data)
    case proto(msg: SteamEMsg, header: CMsgProtoBufHeader, body: Data)
    case unknown(rawEMsg: UInt32)
}

enum SteamFrameError: Error {
    case tooShort
    case malformedHeader
}

enum SteamFraming {
    static func decode(_ data: Data) throws -> SteamIncomingFrame {
        guard data.count >= 4 else { throw SteamFrameError.tooShort }
        let raw = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let stripped = SteamMsgUtil.stripProtoFlag(raw)
        guard let known = SteamEMsg(rawValue: stripped) else {
            return .unknown(rawEMsg: raw)
        }
        switch known {
        case .channelEncryptRequest, .channelEncryptResponse, .channelEncryptResult:
            return .plain(msg: known, payload: data.suffix(from: 20 <= data.count ? 20 : data.count))
        default:
            break
        }
        guard SteamMsgUtil.isProtoBuf(raw) else {
            return .unknown(rawEMsg: raw)
        }
        guard data.count >= 8 else { throw SteamFrameError.tooShort }
        let headerLength = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard data.count >= 8 + Int(headerLength) else { throw SteamFrameError.malformedHeader }
        let headerBytes = data.subdata(in: 8..<(8 + Int(headerLength)))
        let header = try CMsgProtoBufHeader(serializedBytes: headerBytes)
        let body = data.suffix(from: 8 + Int(headerLength))
        return .proto(msg: known, header: header, body: Data(body))
    }

    static func encodeProto(_ msg: SteamEMsg, header: CMsgProtoBufHeader, body: Data) throws -> Data {
        let headerBytes = try header.serializedData()
        var data = Data()
        data.append(littleEndian: SteamMsgUtil.makeProtoMsg(msg))
        data.append(littleEndian: UInt32(headerBytes.count))
        data.append(headerBytes)
        data.append(body)
        return data
    }

    static func encodePlain(_ msg: SteamEMsg, payload: Data) -> Data {
        var data = SteamPlainMsgHeader(msg: msg).serialize()
        data.append(payload)
        return data
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func append(littleEndian value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
