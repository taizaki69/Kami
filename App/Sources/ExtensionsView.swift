import SwiftUI
import MihonCompatKit
import KamiCore

/// Extension store management: add repositories, securely install/update APKs,
/// explicitly confirm legacy-store signers, and enable or disable admitted
/// sources. Installed bytes and enabled state survive app restarts.
struct ExtensionsView: View {
    @EnvironmentObject var model: AppModel

    @State private var adding = false
    @State private var repoURL = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    notice(errorText, color: .orange)
                }
                if let message = model.extensionMessage {
                    notice(message, color: .gray)
                }

                if !model.installedExtensions.isEmpty {
                    Section("Installed") {
                        ForEach(model.installedExtensions, id: \.packageName) { installed in
                            InstalledExtensionRow(installed: installed)
                        }
                    }
                }

                if model.extensionRepositories.isEmpty {
                    Section {
                        Text("No extension repositories added yet.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Installed extensions are restored from authenticated local APKs and do not require the repository to be online.")
                    }
                }

                ForEach(model.extensionRepositories) { repo in
                    Section {
                        if let index = repo.index {
                            ForEach(index.extensions, id: \.packageName) { extensionEntry in
                                ExtensionRow(
                                    extension: extensionEntry,
                                    repositoryURL: repo.record.url,
                                    repositorySigningKey: repo.record.signingKey
                                )
                            }
                        } else {
                            Label(
                                repo.loadError ?? "Repository is currently unavailable.",
                                systemImage: "wifi.exclamationmark"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    } header: {
                        HStack {
                            Text(repo.sectionTitle)
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await model.removeExtensionRepository(
                                        url: repo.record.url
                                    )
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text(repo.record.signingKey == nil
                             ? "This repository does not declare a signing key. Kami will verify the APK and ask you to confirm its certificate fingerprint before the first install."
                             : "First installs must match this repository's declared signing certificate. Updates remain bound to persisted signer continuity.")
                    }
                }
            }
            .navigationTitle("Extensions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) {
                addRepoSheet
            }
            .overlay {
                if busy { ProgressView().scaleEffect(1.2) }
            }
            .alert(item: $model.pendingExtensionTrust) { preparation in
                let fingerprint = preparation.currentSignerFingerprints.first ?? ""
                let displayedFingerprints = preparation.currentSignerFingerprints
                    .joined(separator: "\n")
                return Alert(
                    title: Text("Trust extension signer?"),
                    message: Text("\(preparation.extensionName) \(preparation.versionName) was signed with \(preparation.signatureScheme.rawValue.uppercased()). Verify this SHA-256 certificate signer set before continuing:\n\n\(displayedFingerprints)"),
                    primaryButton: .default(Text("Trust & Install")) {
                        Task {
                            await model.confirmInstall(
                                preparation,
                                fingerprint: fingerprint
                            )
                        }
                    },
                    secondaryButton: .cancel {
                        model.cancelInstall(preparation)
                    }
                )
            }
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Section {
            Label(text, systemImage: "info.circle")
                .foregroundStyle(color)
                .font(.footnote)
        }
    }

    private var addRepoSheet: some View {
        NavigationStack {
            Form {
                TextField("Repository URL", text: $repoURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Section {
                    Text("Both current formats are supported: protobuf index.pb and legacy index.min.json. Use the direct index URL supplied by the repository maintainer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { adding = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        adding = false
                        Task { await addRepo() }
                    }
                    .disabled(repoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func addRepo() async {
        busy = true
        errorText = nil
        let enteredURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await model.addExtensionRepository(url: enteredURL)
            repoURL = ""
        } catch {
            errorText = "Could not add repository: \(describe(error))"
        }
        busy = false
    }

    private func describe(_ error: Error) -> String {
        if let fetchError = error as? ExtensionStoreClient.FetchError {
            switch fetchError {
            case let .badURL(text): return "invalid URL \(text)"
            case let .http(code): return "HTTP \(code) while fetching the index"
            case let .transport(inner): return inner.localizedDescription
            case let .badIndex(message): return "invalid repository index: \(message)"
            case let .responseTooLarge(limit):
                return "repository response exceeds the \(limit / 1_048_576) MB safety limit"
            }
        }
        return error.localizedDescription
    }
}

private struct InstalledExtensionRow: View {
    @EnvironmentObject var model: AppModel
    let installed: InstalledExtensionTrust

    var body: some View {
        Toggle(isOn: Binding(
            get: { installed.enabled },
            set: { enabled in
                Task {
                    await model.setExtensionEnabled(
                        enabled,
                        packageName: installed.packageName
                    )
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(installed.packageName)
                    .lineLimit(1)
                Text("Version \(installed.versionName) · \(installed.signatureScheme.rawValue.uppercased()) · \(trustLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let signer = installed.currentSigners.first {
                    Text("Signer \(signer.prefix(16))…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.extensionBusyPackages.contains(installed.packageName))
    }

    private var trustLabel: String {
        switch installed.trustSource {
        case .repository: return "repository trust"
        case .user: return "user-confirmed signer"
        }
    }
}

private struct ExtensionRow: View {
    @EnvironmentObject var model: AppModel

    let `extension`: ExtensionRepositoryIndex.Extension
    let repositoryURL: String
    let repositorySigningKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(`extension`.name)
                Spacer()
                Text(`extension`.versionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(`extension`.packageName) · lib \(`extension`.extensionLib.isEmpty ? "-" : `extension`.extensionLib) · \(`extension`.sources.count) source(s)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let warning = warningText {
                Label(warning, systemImage: warningIcon)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if model.extensionBusyPackages.contains(`extension`.packageName) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(actionLabel) {
                        Task {
                            await model.install(
                                extension: `extension`,
                                repositoryURL: repositoryURL,
                                repositorySigningKey: repositorySigningKey
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canInstall)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var installed: InstalledExtensionTrust? {
        model.installedExtension(packageName: `extension`.packageName)
    }

    private var canInstall: Bool {
        guard let installed else { return true }
        return `extension`.versionCode > installed.versionCode
    }

    private var actionLabel: String {
        guard let installed else { return "Install" }
        if `extension`.versionCode > installed.versionCode { return "Update" }
        if `extension`.versionCode < installed.versionCode { return "Older version" }
        return "Installed"
    }

    private var warningText: String? {
        switch `extension`.contentWarning {
        case .nsfw: return "18+ content"
        case .mixed: return "Mixed content"
        default: return nil
        }
    }

    private var warningIcon: String {
        `extension`.contentWarning == .nsfw ? "18.circle" : "eye"
    }
}
