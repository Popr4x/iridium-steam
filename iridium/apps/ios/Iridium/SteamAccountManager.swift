import Foundation
import IridiumCore
import IridiumRuntime
import IridiumSteam

enum SteamSignInState: Equatable {
    case signedOut
    case signingIn
    case needsEmailCode
    case needsTwoFactorCode
    case signedIn(accountName: String)
    case failed(String)
}

struct SteamInstallProgress: Identifiable {
    var id: UInt32 { appID }
    let appID: UInt32
    var stage: InstallExecutionStage
    var detail: String
    var fractionComplete: Double
}

/// Drives the real Steam sign-in and install pipeline for the Steam library tab. Login talks
/// to Steam directly (see `RealSteamSession`); installs reuse the existing
/// `NativeSteamInstallCoordinator` state machine backed by a real, network content client.
@MainActor
final class SteamAccountManager: ObservableObject {
    @Published private(set) var state: SteamSignInState = .signedOut
    @Published private(set) var ownedGames: [SteamOwnedGame] = []
    @Published private(set) var installs: [UInt32: SteamInstallProgress] = [:]

    private let session = RealSteamSession()
    private var pendingAccountName: String?
    private var pendingPassword: String?
    private lazy var contentClient = RealSteamContentServerClient(session: session)
    private lazy var coordinator = NativeSteamInstallCoordinator(
        contentClient: contentClient,
        verificationService: DefaultDepotVerificationService()
    )

    var onGameInstalled: ((InstallExecutionRecord, SteamInstallPlan) -> Void)?

    func signIn(accountName: String, password: String) async {
        state = .signingIn
        pendingAccountName = accountName
        pendingPassword = password
        await performSignIn(accountName: accountName, password: password, authCode: nil, twoFactorCode: nil)
    }

    func submitGuardCode(_ code: String) async {
        guard let accountName = pendingAccountName, let password = pendingPassword else { return }
        let needsEmail = state == .needsEmailCode
        state = .signingIn
        await performSignIn(
            accountName: accountName, password: password,
            authCode: needsEmail ? code : nil,
            twoFactorCode: needsEmail ? nil : code
        )
    }

    private func performSignIn(accountName: String, password: String, authCode: String?, twoFactorCode: String?) async {
        do {
            let result = try await session.logOn(accountName: accountName, password: password, authCode: authCode, twoFactorCode: twoFactorCode)
            switch result {
            case .success:
                state = .signedIn(accountName: accountName)
                pendingPassword = nil
                await refreshLibrary()
            case .needsEmailCode:
                state = .needsEmailCode
            case .needsTwoFactorCode:
                state = .needsTwoFactorCode
            case .invalidCredentials:
                state = .failed("Incorrect account name or password.")
            case .invalidCode:
                state = .failed("That code wasn't accepted. Try again.")
            case .rateLimited:
                state = .failed("Too many attempts. Try again later.")
            case let .otherFailure(eresult):
                state = .failed("Steam sign-in failed (\(eresult)).")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        await session.signOut()
        state = .signedOut
        ownedGames = []
        installs = [:]
    }

    func refreshLibrary() async {
        do {
            ownedGames = try await session.ownedGames().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // Keep the current list; the sign-in state already reflects connectivity issues.
        }
    }

    func install(_ game: SteamOwnedGame, into librariesRoot: String) {
        guard installs[game.appID] == nil else { return }
        let targetPath = "\(librariesRoot)/steam/\(game.appID)"
        installs[game.appID] = SteamInstallProgress(appID: game.appID, stage: .queued, detail: "Preparing…", fractionComplete: 0)

        Task {
            do {
                let (plan, manifest) = try await session.resolveInstallPlan(appID: game.appID, title: game.name, targetPath: targetPath)
                try FileManager.default.createDirectory(atPath: targetPath, withIntermediateDirectories: true)

                var execution = InstallExecutionRecord(
                    title: plan.title, appID: plan.appID, buildID: manifest.buildID, branchName: manifest.branchName,
                    targetPath: plan.targetPath, primaryExecutable: plan.primaryExecutable,
                    depotIDs: manifest.depots.map(\.depotID), depotMountPaths: Dictionary(uniqueKeysWithValues: manifest.depots.map { ($0.depotID, $0.mountedPath) }),
                    completedDepotIDs: [], stage: .queued, detail: "Queued.", reservedDiskGB: plan.requiredDiskHeadroomGB
                )

                while execution.stage != .completed {
                    execution = await coordinator.advance(execution: execution, manifest: manifest)
                    let done = Double(execution.completedDepotIDs.count)
                    let total = max(1, Double(manifest.depots.count))
                    installs[game.appID] = SteamInstallProgress(appID: game.appID, stage: execution.stage, detail: execution.detail, fractionComplete: min(1, done / total))
                    if execution.stage == .queued || execution.stage == .resolving { continue }
                    // Yield between ticks so SwiftUI can render progress and the loop stays cancellable.
                    try? await Task.sleep(for: .milliseconds(50))
                }

                installs[game.appID] = SteamInstallProgress(appID: game.appID, stage: .completed, detail: "Installed.", fractionComplete: 1)
                onGameInstalled?(execution, plan)
            } catch {
                installs[game.appID] = SteamInstallProgress(appID: game.appID, stage: .queued, detail: "Install failed: \(error.localizedDescription)", fractionComplete: 0)
            }
        }
    }
}
