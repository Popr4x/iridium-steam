import SwiftUI
import IridiumSteam

struct SteamAccountView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountName = ""
    @State private var password = ""
    @State private var guardCode = ""

    private var manager: SteamAccountManager { viewModel.steamAccountManager }

    var body: some View {
        Form {
            switch manager.state {
            case .signedOut, .failed:
                signInSection
            case .signingIn:
                Section { HStack { ProgressView(); Text("Signing in…") } }
            case .needsEmailCode, .needsTwoFactorCode:
                guardCodeSection
            case let .signedIn(accountName):
                signedInSection(accountName: accountName)
            }
        }
        .iridiumListChrome()
        .navigationTitle("Steam Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }

    private var signInSection: some View {
        Group {
            if case let .failed(message) = manager.state {
                Section { Text(message).foregroundStyle(.red) }
            }
            Section {
                MenuTextField("Account name", text: $accountName).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
            } footer: {
                Text("Iridium downloads games directly from Steam using your account's real login. This talks to Steam's own servers; your password is never stored.")
            }
            Section {
                MenuButton("Sign In") {
                    Task { await manager.signIn(accountName: accountName, password: password) }
                }.disabled(accountName.isEmpty || password.isEmpty).libraryGlass(prominent: true)
            }
        }
    }

    private var guardCodeSection: some View {
        Section {
            TextField(manager.state == .needsEmailCode ? "Email code" : "Authenticator code", text: $guardCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            MenuButton("Continue") {
                Task { await manager.submitGuardCode(guardCode); guardCode = "" }
            }.disabled(guardCode.isEmpty).libraryGlass(prominent: true)
        } footer: {
            Text(manager.state == .needsEmailCode
                ? "Steam sent a code to your account's email address."
                : "Enter the code from your Steam Mobile Authenticator.")
        }
    }

    private func signedInSection(accountName: String) -> some View {
        Group {
            Section {
                LabeledContent("Account", value: accountName)
                MenuButton("Sign Out") { Task { await manager.signOut() } }
            }
            Section("Your Games") {
                if manager.ownedGames.isEmpty {
                    HStack { ProgressView(); Text("Loading library…") }
                        .task { await manager.refreshLibrary() }
                } else {
                    ForEach(manager.ownedGames) { game in
                        ownedGameRow(game)
                    }
                }
            }
        }
    }

    @ViewBuilder private func ownedGameRow(_ game: SteamOwnedGame) -> some View {
        HStack {
            Text(game.name)
            Spacer()
            if let progress = manager.installs[game.appID] {
                if progress.stage == .completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: progress.fractionComplete).frame(width: 90)
                        Text(progress.stage.displayName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Install") {
                    manager.install(game, into: viewModel.steamLibrariesRootPath)
                }.buttonStyle(.bordered)
            }
        }
    }
}
