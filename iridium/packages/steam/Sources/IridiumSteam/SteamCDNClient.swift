import Foundation
import Compression

public struct SteamCDNServer: Sendable {
    let host: String
    let vhost: String
    let usesHTTPS: Bool
}

public struct SteamManifestChunk: Sendable, Hashable {
    public let sha: Data
    public let offset: UInt64
    public let compressedLength: UInt32
    public let uncompressedLength: UInt32
    public let checksum: UInt32
}

public struct SteamManifestFile: Sendable {
    public let filename: String
    public let size: UInt64
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let linkTarget: String
    public let chunks: [SteamManifestChunk]
}

public struct SteamDepotManifestContents: Sendable {
    public let depotID: UInt32
    public let files: [SteamManifestFile]
    public let totalUncompressedBytes: UInt64
}

enum SteamCDNError: Error {
    case requestFailed
    case noServersAvailable
    case malformedManifest
    case malformedChunk
    case unsupportedChunkCompression
}

public enum SteamCDN {
    public static func fetchServers(cellID: Int = 0, urlSession: URLSession = .shared) async throws -> [SteamCDNServer] {
        var components = URLComponents(string: "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/")!
        components.queryItems = [URLQueryItem(name: "cell_id", value: String(cellID))]
        guard let url = components.url else { throw SteamCDNError.requestFailed }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SteamCDNError.requestFailed }
        let decoded = try JSONDecoder().decode(GetServersResponse.self, from: data)
        let servers = decoded.response.servers
            .filter { $0.type == "CDN" }
            .map { SteamCDNServer(host: $0.host, vhost: $0.vhost, usesHTTPS: $0.https_support != "unavailable") }
        guard !servers.isEmpty else { throw SteamCDNError.noServersAvailable }
        return servers
    }

    public static func downloadManifest(
        depotID: UInt32, manifestID: UInt64, server: SteamCDNServer, urlSession: URLSession = .shared
    ) async throws -> SteamDepotManifestContents {
        let scheme = server.usesHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(server.host)/depot/\(depotID)/manifest/\(manifestID)/5") else {
            throw SteamCDNError.requestFailed
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SteamCDNError.requestFailed }
        let unzipped = try SteamZip.decompressSingleEntry(data)
        return try parseManifest(unzipped, depotID: depotID)
    }

    public static func downloadChunk(
        depotID: UInt32, chunk: SteamManifestChunk, server: SteamCDNServer, depotKey: Data, urlSession: URLSession = .shared
    ) async throws -> Data {
        let scheme = server.usesHTTPS ? "https" : "http"
        let chunkID = chunk.sha.map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(scheme)://\(server.host)/depot/\(depotID)/chunk/\(chunkID)") else {
            throw SteamCDNError.requestFailed
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SteamCDNError.requestFailed }
        return try decryptAndDecompressChunk(data, depotKey: depotKey, expectedUncompressedLength: Int(chunk.uncompressedLength), expectedChecksum: chunk.checksum)
    }

    private static func decryptAndDecompressChunk(_ data: Data, depotKey: Data, expectedUncompressedLength: Int, expectedChecksum: UInt32) throws -> Data {
        let plain = try SteamCrypto.aesDecryptIVFirst(data, key: depotKey)
        guard plain.count >= 4 else { throw SteamCDNError.malformedChunk }
        let magic = plain.prefix(4)
        let decompressed: Data
        if magic[magic.startIndex] == 0x56, magic[magic.startIndex + 1] == 0x53, magic[magic.startIndex + 2] == 0x5A, magic[magic.startIndex + 3] == 0x61 {
            // "VSZa" - Zstd
            decompressed = try decompressVZstd(plain)
        } else if magic[magic.startIndex] == 0x56, magic[magic.startIndex + 1] == 0x5A, magic[magic.startIndex + 2] == 0x61 {
            // "VZa" - LZMA
            decompressed = try decompressVZip(plain)
        } else if magic[magic.startIndex] == 0x50, magic[magic.startIndex + 1] == 0x4B {
            // "PK" - stored zip
            decompressed = try SteamZip.decompressSingleEntry(plain)
        } else {
            throw SteamCDNError.unsupportedChunkCompression
        }
        guard decompressed.count == expectedUncompressedLength else { throw SteamCDNError.malformedChunk }
        return decompressed
    }

    private static func decompressVZip(_ data: Data) throws -> Data {
        // Layout: 'V''Z''a'(3) + timestampOrCRC(4) + lzmaPropByte(1) + dictSize(4LE) + payload... + crc(4) + size(4) + 'z''v'(2)
        guard data.count >= 7 + 10 else { throw SteamCDNError.malformedChunk }
        let propByte = data[data.startIndex + 7]
        let dictSize = data.subdata(in: (data.startIndex + 8)..<(data.startIndex + 12)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let payloadStart = data.startIndex + 12
        let footerStart = data.endIndex - 10
        guard payloadStart <= footerStart else { throw SteamCDNError.malformedChunk }
        let sizeDecompressed = data.subdata(in: (footerStart + 4)..<(footerStart + 8)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        let compressedPayload = data.subdata(in: payloadStart..<footerStart)
        return try SteamLZMA.decodeLZMAAlone(propByte: propByte, dictSize: dictSize, uncompressedSize: UInt64(sizeDecompressed), compressed: compressedPayload)
    }

    /// Apple's Compression framework has no Zstandard decoder, and this package does not
    /// currently bundle one. Many modern depots compress chunks with Zstd ("VSZa" chunks), so
    /// this is a known coverage gap: those chunks fail to download until a zstd decoder is
    /// wired in (e.g. vendoring libzstd as a binary target).
    private static func decompressVZstd(_ data: Data) throws -> Data {
        throw SteamCDNError.unsupportedChunkCompression
    }

    private static func parseManifest(_ data: Data, depotID: UInt32) throws -> SteamDepotManifestContents {
        var payload: ContentManifestPayload?
        var index = data.startIndex
        while index + 4 <= data.endIndex {
            let magic = data.subdata(in: index..<(index + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            index += 4
            switch magic {
            case 0x71F6_17D0: // payload
                guard index + 4 <= data.endIndex else { throw SteamCDNError.malformedManifest }
                let length = Int(data.subdata(in: index..<(index + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                index += 4
                guard index + length <= data.endIndex else { throw SteamCDNError.malformedManifest }
                payload = try ContentManifestPayload(serializedBytes: data.subdata(in: index..<(index + length)))
                index += length
            case 0x1F48_12BE, 0x1B81_B817: // metadata / signature: length-prefixed, skip
                guard index + 4 <= data.endIndex else { throw SteamCDNError.malformedManifest }
                let length = Int(data.subdata(in: index..<(index + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                index += 4 + length
            case 0x32C4_15AB: // end of manifest
                index = data.endIndex
            default:
                throw SteamCDNError.malformedManifest
            }
        }
        guard let payload else { throw SteamCDNError.malformedManifest }
        var totalBytes: UInt64 = 0
        let files: [SteamManifestFile] = payload.mappings.map { mapping in
            totalBytes += mapping.size
            let chunks = mapping.chunks.map {
                SteamManifestChunk(sha: $0.sha, offset: $0.offset, compressedLength: $0.cbCompressed, uncompressedLength: $0.cbOriginal, checksum: $0.crc)
            }
            let isDirectory = mapping.flags & 0x0000_0010 != 0
            let isSymlink = !mapping.linktarget.isEmpty
            return SteamManifestFile(filename: mapping.filename, size: mapping.size, isDirectory: isDirectory, isSymlink: isSymlink, linkTarget: mapping.linktarget, chunks: chunks)
        }
        return SteamDepotManifestContents(depotID: depotID, files: files, totalUncompressedBytes: totalBytes)
    }

    private struct GetServersResponse: Decodable {
        let response: Inner
        struct Inner: Decodable { let servers: [Entry] }
        struct Entry: Decodable {
            let type: String
            let host: String
            let vhost: String
            let https_support: String
        }
    }
}
