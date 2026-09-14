import Foundation
import IridiumCore
import IridiumSteam

/// Real, network-backed Steam session used by the app's Steam tab: login, owned-games sync,
/// and per-app depot/branch resolution. This is intentionally separate from the file-bridge
/// `SteamAuthClient`/`SteamCatalogClient` protocols in `SteamHostIntegration.swift` (those are
/// for cross-process bridging and carry no password field) — the app talks to Steam directly
/// in-process and only reuses `SteamInstallCoordinator`/`DepotVerificationService` for the
/// download state machine via `RealSteamContentServerClient` below.
public actor RealSteamSession {
    public private(set) var client: SteamClient?

    public init() {}

    public func logOn(accountName: String, password: String, authCode: String? = nil, twoFactorCode: String? = nil) async throws -> SteamLoginResult {
        let client = SteamClient()
        try await client.connect()
        let result = try await client.logOn(accountName: accountName, password: password, authCode: authCode, twoFactorCode: twoFactorCode)
        if case .success = result {
            self.client = client
        } else if case .needsEmailCode = result {
            self.client = client
        } else if case .needsTwoFactorCode = result {
            self.client = client
        } else {
            await client.disconnect()
        }
        return result
    }

    public func signOut() async {
        await client?.disconnect()
        client = nil
    }

    public func ownedGames() async throws -> [SteamOwnedGame] {
        guard let client else { throw RealSteamError.notSignedIn }
        return try await client.syncOwnedGames()
    }

    /// Resolves the public-branch depot list for an app into the pipeline's coarse models.
    /// Depot byte sizes are filled in from each depot's manifest metadata (one CDN round trip
    /// per depot), so this call can take a few seconds for multi-depot titles.
    public func resolveInstallPlan(appID: UInt32, title: String, targetPath: String) async throws -> (plan: SteamInstallPlan, manifest: SteamManifestResolution) {
        guard let client else { throw RealSteamError.notSignedIn }
        let resolution = try await SteamDepotResolver.resolve(client: client, appID: appID, title: title, targetPath: targetPath)
        return resolution
    }
}

enum RealSteamError: Error {
    case notSignedIn
    case noPublicDepots
    case depotResolutionFailed
}

/// Resolves an app's owned, Windows-installable depots from PICS appinfo into the download
/// pipeline's `SteamInstallPlan`/`SteamManifestResolution` shapes.
enum SteamDepotResolver {
    static func resolve(client: SteamClient, appID: UInt32, title: String, targetPath: String) async throws -> (SteamInstallPlan, SteamManifestResolution) {
        let appInfo = try await client.fetchRawAppInfo(appID: appID)
        guard case let .dict(root) = appInfo else { throw RealSteamError.depotResolutionFailed }
        let fields: SteamKeyValue = root["depots"] != nil ? appInfo : (root.values.first ?? appInfo)

        let installDir = fields["config"]?["installdir"]?.stringValue ?? title
        let launchExecutable = firstWindowsExecutable(in: fields["config"]?["launch"]) ?? "\(installDir).exe"
        let buildID = fields["depots"]?["branches"]?["public"]?["buildid"]?.stringValue ?? "0"

        guard case let .dict(depotsDict)? = fields["depots"] else { throw RealSteamError.noPublicDepots }
        var depots: [SteamDepotManifest] = []
        for (key, value) in depotsDict {
            guard let depotID = UInt32(key) else { continue }
            guard let osList = value["config"]?["oslist"]?.stringValue else {
                // Depots with no oslist restriction are shared/OS-agnostic; include them too.
                if let gid = value["manifests"]?["public"]?["gid"]?.stringValue, let manifestID = UInt64(gid) {
                    depots.append(SteamDepotManifest(depotID: String(depotID), manifestID: String(manifestID), label: value["name"]?.stringValue ?? "Depot \(depotID)", compressedSizeGB: 0, mountedPath: "\(targetPath)/depot-\(depotID)"))
                }
                continue
            }
            guard osList.lowercased().contains("windows") else { continue }
            guard let gid = value["manifests"]?["public"]?["gid"]?.stringValue, let manifestID = UInt64(gid) else { continue }
            depots.append(SteamDepotManifest(depotID: String(depotID), manifestID: String(manifestID), label: value["name"]?.stringValue ?? "Depot \(depotID)", compressedSizeGB: 0, mountedPath: "\(targetPath)/depot-\(depotID)"))
        }
        guard !depots.isEmpty else { throw RealSteamError.noPublicDepots }

        let manifest = SteamManifestResolution(
            title: title, appID: String(appID), buildID: buildID, branchName: "public",
            depots: depots, verificationStages: ["chunk-checksums"]
        )
        let plan = SteamInstallPlan(
            title: title, appID: String(appID), targetPath: targetPath,
            primaryExecutable: "\(targetPath)/\(installDir)/\(launchExecutable)",
            contentSets: depots.map(\.label), estimatedInstallSizeGB: 0,
            requiredDiskHeadroomGB: 2, verificationSteps: ["chunk-checksums"]
        )
        return (plan, manifest)
    }

    private static func firstWindowsExecutable(in launch: SteamKeyValue?) -> String? {
        guard case let .dict(entries)? = launch else { return nil }
        for (_, entry) in entries {
            let osList = entry["config"]?["oslist"]?.stringValue ?? "windows"
            guard osList.lowercased().contains("windows") || osList.isEmpty else { continue }
            if let executable = entry["executable"]?.stringValue { return executable }
        }
        return nil
    }
}

/// Real `SteamContentServerClient`: downloads and decrypts depot chunks from Steam's CDN in
/// bounded batches per `transfer()` call (matching the existing simulated clients' contract of
/// making incremental progress per invocation), writing files directly under
/// `execution.targetPath`. Depot manifests and CDN server selection are cached per depot ID.
public actor RealSteamContentServerClient: SteamContentServerClient {
    private let session: RealSteamSession
    private var manifestCache: [String: SteamDepotManifestContents] = [:]
    private var cdnServers: [SteamCDNServer] = []
    private var depotKeyCache: [UInt32: Data] = [:]
    private let batchByteBudget: Int64 = 128 * 1024 * 1024

    public init(session: RealSteamSession) {
        self.session = session
    }

    public func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String) {
        do {
            return try await realTransfer(depot: depot, into: execution)
        } catch {
            // Report no progress; the coordinator will retry on the next tick.
            let current = execution.depotProgressBytes[depot.depotID] ?? 0
            return (current, execution.resumeCheckpoint ?? "\(depot.depotID):0")
        }
    }

    private func realTransfer(depot: SteamDepotManifest, into execution: InstallExecutionRecord) async throws -> (Int64, String) {
        guard let depotID = UInt32(depot.depotID), let manifestID = UInt64(depot.manifestID) else {
            throw RealSteamError.depotResolutionFailed
        }
        guard let client = await session.client else { throw RealSteamError.notSignedIn }

        let manifest = try await cachedManifest(depotID: depotID, manifestID: manifestID)
        let depotKey = try await cachedDepotKey(client: client, appID: UInt32(execution.appID) ?? 0, depotID: depotID)
        let server = try await cachedServer()

        let allChunks: [(file: SteamManifestFile, chunk: SteamManifestChunk)] = manifest.files.flatMap { file in
            file.isDirectory || file.isSymlink ? [] : file.chunks.map { (file, $0) }
        }
        let totalBytes = manifest.totalUncompressedBytes
        var writtenBytes = execution.depotProgressBytes[depot.depotID] ?? 0
        let alreadyDone = Set((execution.resumeCheckpoint?.split(separator: "|").first(where: { $0.hasPrefix("\(depot.depotID):") })?
            .dropFirst(depot.depotID.count + 1) ?? "").split(separator: ",").map(String.init))

        var newlyDone: [String] = []
        var batchBytes: Int64 = 0
        let root = URL(fileURLWithPath: depot.mountedPath)

        for (file, chunk) in allChunks {
            let chunkKey = chunk.sha.map { String(format: "%02x", $0) }.joined()
            if alreadyDone.contains(chunkKey) { continue }
            if batchBytes >= batchByteBudget { break }

            let decrypted = try await SteamCDN.downloadChunk(depotID: depotID, chunk: chunk, server: server, depotKey: depotKey)
            let fileURL = root.appendingPathComponent(file.filename)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: chunk.offset)
            try handle.write(contentsOf: decrypted)

            writtenBytes += Int64(decrypted.count)
            batchBytes += Int64(decrypted.count)
            newlyDone.append(chunkKey)
        }

        let doneList = (Array(alreadyDone) + newlyDone).joined(separator: ",")
        let checkpoint = "\(depot.depotID):\(doneList)"
        if writtenBytes >= Int64(totalBytes) {
            writtenBytes = Int64(totalBytes)
        }
        return (writtenBytes, checkpoint)
    }

    private func cachedManifest(depotID: UInt32, manifestID: UInt64) async throws -> SteamDepotManifestContents {
        let key = "\(depotID):\(manifestID)"
        if let cached = manifestCache[key] { return cached }
        let server = try await cachedServer()
        let manifest = try await SteamCDN.downloadManifest(depotID: depotID, manifestID: manifestID, server: server)
        manifestCache[key] = manifest
        return manifest
    }

    private func cachedDepotKey(client: SteamClient, appID: UInt32, depotID: UInt32) async throws -> Data {
        if let cached = depotKeyCache[depotID] { return cached }
        let key = try await client.requestDepotKey(appID: appID, depotID: depotID)
        depotKeyCache[depotID] = key
        return key
    }

    private func cachedServer() async throws -> SteamCDNServer {
        if let server = cdnServers.first { return server }
        cdnServers = try await SteamCDN.fetchServers()
        guard let server = cdnServers.first else { throw RealSteamError.depotResolutionFailed }
        return server
    }
}
