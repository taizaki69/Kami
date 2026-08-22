import SwiftUI
import MihonCompatKit

/// Extension store management: add repositories (both index formats),
/// browse their extensions, download + locally analyze APKs.
struct ExtensionsView: View {
    @EnvironmentObject var model: AppModel

    @State private var repos: [ExtensionRepositoryIndex] = []
    @State private var adding = false
    @State private var repoURL = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
                if repos.isEmpty {
                    Section {
                        Text("No extension repositories added yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(repos, id: \.storeName) { repo in
                    Section("\(repo.storeName)\(repo.badgeLabel.map { " · \($0)" } ?? "")") {
                        ForEach(repo.extensions, id: \.packageName) { ext in
                            ExtensionRow(extension: ext)
                        }
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
        }
    }

    private var addRepoSheet: some View {
        NavigationStack {
            Form {
                TextField("Repository URL", text: $repoURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Section {
                    Text("""
                    Both current formats are supported: the new protobuf store \
                    index (index.pb, Mihon 0.20.1+) and the legacy JSON index \
                    (index.min.json). Example: https://github.com/keiyoushi/extensions
                    """)
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
                    .disabled(repoURL.isEmpty || busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func addRepo() async {
        busy = true
        errorText = nil
        do {
            let index = try await model.storeClient.fetchIndex(repoURL)
            repos.append(index)
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

struct ExtensionRow: View {
    let `extension`: ExtensionRepositoryIndex.Extension

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .padding(.vertical, 2)
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
