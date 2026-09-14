import Foundation

struct SteamCMServer: Sendable {
    let host: String
    let port: Int
}

enum SteamCMServerListError: Error {
    case requestFailed
    case noServersAvailable
}

/// Fetches the current CM (connection manager) websocket server list from Steam's public,
/// unauthenticated directory endpoint. Steam has deprecated raw TCP CM connections in favor
/// of WebSocket, so only `websockets`-type entries are used.
enum SteamCMServerList {
    static func fetch(cellID: Int = 0, urlSession: URLSession = .shared) async throws -> [SteamCMServer] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/")!
        components.queryItems = [
            URLQueryItem(name: "cellid", value: String(cellID)),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw SteamCMServerListError.requestFailed }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamCMServerListError.requestFailed
        }
        let decoded = try JSONDecoder().decode(GetCMListResponse.self, from: data)
        let servers: [SteamCMServer] = decoded.response.serverlist.compactMap { entry in
            guard entry.type == "websockets" else { return nil }
            let parts = entry.endpoint.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else { return nil }
            return SteamCMServer(host: String(parts[0]), port: port)
        }
        guard !servers.isEmpty else { throw SteamCMServerListError.noServersAvailable }
        return servers
    }

    private struct GetCMListResponse: Decodable {
        let response: Inner
        struct Inner: Decodable {
            let serverlist: [Entry]
        }
        struct Entry: Decodable {
            let endpoint: String
            let type: String
        }
    }
}
