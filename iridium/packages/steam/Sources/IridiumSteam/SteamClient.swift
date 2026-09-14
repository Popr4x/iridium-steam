import Foundation

public enum SteamLoginResult: Sendable {
    case success(steamID: UInt64)
    case needsEmailCode
    case needsTwoFactorCode
    case invalidCredentials
    case invalidCode
    case rateLimited
    case otherFailure(eresult: Int32)
}

public struct SteamOwnedGame: Sendable, Hashable, Identifiable {
    public var id: UInt32 { appID }
    public let appID: UInt32
    public let name: String
    public let installDirectory: String?
}

enum SteamClientError: Error {
    case notConnected
    case notLoggedOn
    case unexpectedResponse
}

/// Orchestrates a single Steam session: connect to a CM server, log on, sync owned licenses,
/// and resolve PICS app info into a lightweight owned-games list. One instance is one session;
/// callers keep it alive for the lifetime of a signed-in account.
public actor SteamClient {
    private var connection: SteamCMConnection?
    private var steamID: UInt64 = 0
    private var sessionID: Int32 = 0
    private var cellID: UInt32 = 0

    public init() {}

    public func connect() async throws {
        let servers = try await SteamCMServerList.fetch()
        guard let server = servers.randomElement() else { throw SteamClientError.notConnected }
        connection = try await SteamCMConnection.connect(to: server)
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
        steamID = 0
        sessionID = 0
    }

    public func logOn(accountName: String, password: String, authCode: String? = nil, twoFactorCode: String? = nil) async throws -> SteamLoginResult {
        guard let connection else { throw SteamClientError.notConnected }

        var logon = CMsgClientLogon()
        logon.accountName = accountName
        logon.password = password
        logon.protocolVersion = 65580
        logon.clientOsType = 20 // EOSType.MacOSUnknown-ish sentinel; server tolerates unknown values
        logon.clientLanguage = "english"
        logon.shouldRememberPassword = false
        if let authCode { logon.authCode = authCode }
        if let twoFactorCode { logon.twoFactorCode = twoFactorCode }

        var header = CMsgProtoBufHeader()
        header.clientSessionid = 0

        try await connection.send(msg: .clientLogon, header: header, body: try logon.serializedData())

        while true {
            let frame = try await connection.receive()
            guard case let .proto(msg, respHeader, body) = frame else { continue }
            if msg == .clientLogOnResponse {
                let response = try CMsgClientLogonResponse(serializedBytes: body)
                if response.eresult == 1 {
                    self.steamID = respHeader.steamid
                    self.sessionID = respHeader.clientSessionid
                    self.cellID = response.cellID
                    return .success(steamID: respHeader.steamid)
                }
                switch response.eresult {
                case 5: return .invalidCredentials
                case 63: return .needsEmailCode
                case 65, 88: return .invalidCode
                case 85: return .needsTwoFactorCode
                case 84: return .rateLimited
                default: return .otherFailure(eresult: response.eresult)
                }
            }
        }
    }

    /// Fetches the account's owned licenses (packages), resolves them to app IDs, then fetches
    /// lightweight app info (name, install directory) for each. Requires a prior successful logOn.
    public func syncOwnedGames() async throws -> [SteamOwnedGame] {
        guard let connection, steamID != 0 else { throw SteamClientError.notLoggedOn }

        let packageIDs = try await receiveLicenseList(connection)
        guard !packageIDs.isEmpty else { return [] }

        let packageTokens = try await requestPICSAccessTokens(connection, packageIDs: packageIDs, appIDs: [])
        let appIDs = try await requestPackageInfo(connection, packageIDs: packageIDs, tokens: packageTokens.packages)
        guard !appIDs.isEmpty else { return [] }

        let appTokens = try await requestPICSAccessTokens(connection, packageIDs: [], appIDs: Array(appIDs))
        return try await requestAppInfo(connection, appIDs: Array(appIDs), tokens: appTokens.apps)
    }

    /// Fetches the full binary-VDF app info tree for one app (used to resolve its depot list).
    public func fetchRawAppInfo(appID: UInt32) async throws -> SteamKeyValue {
        guard let connection else { throw SteamClientError.notConnected }
        let tokens = try await requestPICSAccessTokens(connection, packageIDs: [], appIDs: [appID])

        var request = CMsgClientPICSProductInfoRequest()
        var info = CMsgClientPICSProductInfoRequest.AppInfo()
        info.appid = appID
        info.accessToken = tokens.apps[appID] ?? 0
        request.apps = [info]
        try await connection.send(msg: .clientPICSProductInfoRequest, header: makeHeader(), body: try request.serializedData())

        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            guard msg == .clientPICSProductInfoResponse else { continue }
            let response = try CMsgClientPICSProductInfoResponse(serializedBytes: body)
            if let app = response.apps.first(where: { $0.appid == appID }) {
                return try SteamBinaryKeyValues.parseAppInfoBuffer(app.buffer)
            }
            if !response.responsePending { throw SteamClientError.unexpectedResponse }
        }
    }

    public func requestDepotKey(appID: UInt32, depotID: UInt32) async throws -> Data {
        guard let connection else { throw SteamClientError.notConnected }
        var request = CMsgClientGetDepotDecryptionKey()
        request.appID = appID
        request.depotID = depotID
        try await connection.send(msg: .clientGetDepotDecryptionKey, header: makeHeader(), body: try request.serializedData())
        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            if msg == .clientGetDepotDecryptionKeyResponse {
                let response = try CMsgClientGetDepotDecryptionKeyResponse(serializedBytes: body)
                guard response.eresult == 1 else { throw SteamClientError.unexpectedResponse }
                return response.depotEncryptionKey
            }
        }
    }

    private func makeHeader() -> CMsgProtoBufHeader {
        var header = CMsgProtoBufHeader()
        header.steamid = steamID
        header.clientSessionid = sessionID
        return header
    }

    private func receiveLicenseList(_ connection: SteamCMConnection) async throws -> [UInt32] {
        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            if msg == .clientLicenseList {
                let list = try CMsgClientLicenseList(serializedBytes: body)
                return list.licenses.map(\.packageID)
            }
        }
    }

    private struct PICSTokens { var packages: [UInt32: UInt64]; var apps: [UInt32: UInt64] }

    private func requestPICSAccessTokens(_ connection: SteamCMConnection, packageIDs: [UInt32], appIDs: [UInt32]) async throws -> PICSTokens {
        var request = CMsgClientPICSAccessTokenRequest()
        request.packageids = packageIDs
        request.appids = appIDs
        try await connection.send(msg: .clientPICSAccessTokenRequest, header: makeHeader(), body: try request.serializedData())
        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            if msg == .clientPICSAccessTokenResponse {
                let response = try CMsgClientPICSAccessTokenResponse(serializedBytes: body)
                var packages: [UInt32: UInt64] = [:]
                for token in response.packageAccessTokens { packages[token.packageid] = token.accessToken }
                var apps: [UInt32: UInt64] = [:]
                for token in response.appAccessTokens { apps[token.appid] = token.accessToken }
                return PICSTokens(packages: packages, apps: apps)
            }
        }
    }

    private func requestPackageInfo(_ connection: SteamCMConnection, packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var request = CMsgClientPICSProductInfoRequest()
        request.packages = packageIDs.map {
            var info = CMsgClientPICSProductInfoRequest.PackageInfo()
            info.packageid = $0
            info.accessToken = tokens[$0] ?? 0
            return info
        }
        try await connection.send(msg: .clientPICSProductInfoRequest, header: makeHeader(), body: try request.serializedData())

        var appIDs: Set<UInt32> = []
        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            guard msg == .clientPICSProductInfoResponse else { continue }
            let response = try CMsgClientPICSProductInfoResponse(serializedBytes: body)
            for package in response.packages {
                guard let parsed = try? SteamBinaryKeyValues.parseAppInfoBuffer(package.buffer),
                      case let .dict(root) = parsed else { continue }
                // The package's own fields may be the buffer's root, or nested one level under
                // a packageid-keyed wrapper depending on Steam's appinfo format revision.
                let fields: SteamKeyValue = parsed["appids"] != nil ? parsed : (root.values.first ?? parsed)
                guard case let .dict(appsDict)? = fields["appids"] else { continue }
                for (_, value) in appsDict {
                    if let appID = value.intValue { appIDs.insert(UInt32(appID)) }
                }
            }
            if !response.responsePending { break }
        }
        return appIDs
    }

    private func requestAppInfo(_ connection: SteamCMConnection, appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamOwnedGame] {
        var request = CMsgClientPICSProductInfoRequest()
        request.apps = appIDs.map {
            var info = CMsgClientPICSProductInfoRequest.AppInfo()
            info.appid = $0
            info.accessToken = tokens[$0] ?? 0
            return info
        }
        try await connection.send(msg: .clientPICSProductInfoRequest, header: makeHeader(), body: try request.serializedData())

        var games: [SteamOwnedGame] = []
        while true {
            guard case let .proto(msg, _, body) = try await connection.receive() else { continue }
            guard msg == .clientPICSProductInfoResponse else { continue }
            let response = try CMsgClientPICSProductInfoResponse(serializedBytes: body)
            for app in response.apps {
                guard let parsed = try? SteamBinaryKeyValues.parseAppInfoBuffer(app.buffer),
                      case let .dict(root) = parsed, case let .dict(common)? = root["common"] else { continue }
                let name = common["name"]?.stringValue ?? "App \(app.appid)"
                let type = common["type"]?.stringValue?.lowercased() ?? "game"
                guard type == "game" || type == "application" else { continue }
                let installDir = root["config"]?["installdir"]?.stringValue
                games.append(SteamOwnedGame(appID: app.appid, name: name, installDirectory: installDir))
            }
            if !response.responsePending { break }
        }
        return games
    }
}
