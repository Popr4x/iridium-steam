import Foundation
import Security

enum SteamCMConnectionError: Error {
    case connectFailed
    case handshakeFailed
    case notConnected
    case sendFailed
    case unexpectedFrame
}

/// A single websocket connection to a Steam CM (connection manager) server, handling the
/// envelope-encryption handshake and exposing decrypted protobuf frames.
///
/// Wire format matches SteamKit's `WebSocketConnection` + `EnvelopeEncryptedConnection`:
/// each websocket binary frame is one Steam message (no extra length framing), and after the
/// `ChannelEncryptRequest`/`ChannelEncryptResponse`/`ChannelEncryptResult` handshake every frame
/// is AES-256-CBC encrypted with an HMAC-derived IV.
actor SteamCMConnection {
    private let task: URLSessionWebSocketTask
    private var sessionKey: Data?
    private var encrypted = false

    private init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    static func connect(to server: SteamCMServer, urlSession: URLSession = .shared) async throws -> SteamCMConnection {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = server.host
        components.port = server.port
        components.path = "/cmsocket/"
        guard let url = components.url else { throw SteamCMConnectionError.connectFailed }
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        let connection = SteamCMConnection(task: task)
        try await connection.performHandshake()
        return connection
    }

    private func performHandshake() async throws {
        // First frame from the server is a plain ChannelEncryptRequest.
        guard case let .plain(msg, payload) = try await receiveRawFrame(), msg == .channelEncryptRequest else {
            throw SteamCMConnectionError.handshakeFailed
        }
        // Payload: uint32 protocolVersion, int32 universe, then >=16 bytes random challenge.
        guard payload.count >= 8 + 16 else { throw SteamCMConnectionError.handshakeFailed }
        let randomChallenge = payload.suffix(from: 8)

        let tempSessionKey = Data(SteamRandom.bytes(32))
        var blobToEncrypt = tempSessionKey
        blobToEncrypt.append(randomChallenge)
        let encryptedBlob = try SteamCrypto.rsaEncryptOAEPSHA1(blobToEncrypt)
        let keyCRC = SteamCrypto.crc32(encryptedBlob)

        var payloadOut = Data()
        payloadOut.append(littleEndian: UInt32(1)) // MsgChannelEncryptResponse.ProtocolVersion
        payloadOut.append(littleEndian: UInt32(128)) // MsgChannelEncryptResponse.KeySize (bytes, RSA-1024 -> 128)
        payloadOut.append(encryptedBlob)
        payloadOut.append(littleEndian: keyCRC)
        payloadOut.append(littleEndian: UInt32(0))

        let frame = SteamFraming.encodePlain(.channelEncryptResponse, payload: payloadOut)
        try await sendRaw(frame)
        self.sessionKey = tempSessionKey

        guard case let .plain(resultMsg, resultPayload) = try await receiveRawFrame(), resultMsg == .channelEncryptResult else {
            throw SteamCMConnectionError.handshakeFailed
        }
        guard resultPayload.count >= 4 else { throw SteamCMConnectionError.handshakeFailed }
        let eresult = resultPayload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        guard eresult == 1 else { throw SteamCMConnectionError.handshakeFailed } // EResult.OK
        encrypted = true
    }

    func send(msg: SteamEMsg, header: CMsgProtoBufHeader, body: Data) async throws {
        let frame = try SteamFraming.encodeProto(msg, header: header, body: body)
        try await sendRaw(frame)
    }

    func receive() async throws -> SteamIncomingFrame {
        let frame = try await receiveRawFrame()
        if case .plain = frame { return frame }
        return frame
    }

    private func sendRaw(_ data: Data) async throws {
        let outgoing: Data
        if encrypted, let sessionKey {
            outgoing = try SteamCrypto.aesEncryptHMACIV(data, key: sessionKey)
        } else {
            outgoing = data
        }
        try await task.send(.data(outgoing))
    }

    private func receiveRawFrame() async throws -> SteamIncomingFrame {
        let message = try await task.receive()
        let raw: Data
        switch message {
        case let .data(data): raw = data
        case let .string(str): raw = Data(str.utf8)
        @unknown default: throw SteamCMConnectionError.unexpectedFrame
        }
        let plaintext: Data
        if encrypted, let sessionKey {
            plaintext = try SteamCrypto.aesDecryptHMACIV(raw, key: sessionKey)
        } else {
            plaintext = raw
        }
        return try SteamFraming.decode(plaintext)
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

enum SteamRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}
