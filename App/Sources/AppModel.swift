import SwiftUI
import MihonCompatKit
import KamiCore

struct ExtensionRepositoryState: Identifiable {
    let record: ExtensionRepositoryRecord
    let index: ExtensionRepositoryIndex?
    let loadError: String?

    var id: String { record.url }
    var displayName: String { index?.storeName ?? record.name }
    var sectionTitle: String {
        displayName + ((index?.badgeLabel).map { " · \($0)" } ?? "")
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store: LibraryStore
    let registry: SourceRegistry
    let storeClient: ExtensionStoreClient
    let admissionService: ExtensionAdmissionService
    let installationService: ExtensionInstallationService
    let sourceFactory: ExtensionSourceFactory

    @Published var library: [Manga] = []
    @Published var loading = false
    @Published private(set) var installedExtensions: [InstalledExtensionTrust] = []
    @Published private(set) var extensionBusyPackages = Set<String>()
    @Published var pendingExtensionTrust: ExtensionInstallPreparation?
    @Published var extensionMessage: String?
    @Published private(set) var sourceGeneration: UInt64 = 0
    @Published private(set) var extensionRepositories: [ExtensionRepositoryState] = []

    init() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kami", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbPath = url.appendingPathComponent("kami.sqlite").path

        let store = (try? LibraryStore(path: dbPath)) ?? (try! LibraryStore(inMemory: true))
        let storeClient = ExtensionStoreClient()
        let admissionService = ExtensionAdmissionService(store: store)
        self.store = store
        self.registry = SourceRegistry()
        self.storeClient = storeClient
        self.admissionService = admissionService
        self.installationService = ExtensionInstallationService(
            store: store,
            admissionService: admissionService,
            rootDirectory: url.appendingPathComponent("Extensions", isDirectory: true),
            client: storeClient
        )
        self.sourceFactory = ExtensionSourceFactory()
        reloadLibrary()
        Task { [weak self] in
            await self?.restoreInstalledExtensions()
            await self?.reloadExtensionRepositories()
        }
    }

    func reloadLibrary() {
        Task {
            library = (try? await store.libraryManga()) ?? []
        }
    }

    func source(id: Int64) -> (any KamiSource)? {
        registry.source(id: id)
    }

    var sources: [any KamiSource] {
        _ = sourceGeneration
        return registry.sources
    }

    func sourceOrigin(id: Int64) -> SourceOrigin? {
        registry.origin(of: id)
    }

    func installedExtension(packageName: String) -> InstalledExtensionTrust? {
        installedExtensions.first { $0.packageName == packageName }
    }

    func addExtensionRepository(url: String) async throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try await storeClient.fetchIndex(trimmed)
        let record = try await store.upsertExtensionRepository(
            url: trimmed,
            name: index.storeName,
            signingKey: index.signingKey
        )
        extensionRepositories.removeAll { $0.id == record.id }
        extensionRepositories.append(
            ExtensionRepositoryState(record: record, index: index, loadError: nil)
        )
        extensionRepositories.sort {
            ($0.record.addedAt, $0.record.url) < ($1.record.addedAt, $1.record.url)
        }
    }

    func removeExtensionRepository(url: String) async {
        try? await store.removeExtensionRepository(url: url)
        extensionRepositories.removeAll { $0.record.url == url }
    }

    func install(
        extension extensionEntry: ExtensionRepositoryIndex.Extension,
        repositoryURL: String,
        repositorySigningKey: String?
    ) async {
        let packageName = extensionEntry.packageName
        guard !extensionBusyPackages.contains(packageName) else { return }
        extensionBusyPackages.insert(packageName)
        extensionMessage = nil
        defer { extensionBusyPackages.remove(packageName) }

        do {
            let outcome = try await installationService.beginInstall(
                extension: extensionEntry,
                repositoryURL: repositoryURL,
                repositorySigningKey: repositorySigningKey
            )
            switch outcome {
            case let .installed(admission):
                try await finishInstall(admission)
            case let .requiresUserTrust(preparation):
                pendingExtensionTrust = preparation
            }
        } catch {
            extensionMessage = "Installation failed: \(describeExtensionError(error))"
        }
    }

    func confirmInstall(
        _ preparation: ExtensionInstallPreparation,
        fingerprint: String
    ) async {
        let packageName = preparation.packageName
        guard !extensionBusyPackages.contains(packageName) else { return }
        extensionBusyPackages.insert(packageName)
        pendingExtensionTrust = nil
        extensionMessage = nil
        defer { extensionBusyPackages.remove(packageName) }

        do {
            let admission = try await installationService.confirmUserTrust(
                preparation,
                fingerprint: fingerprint
            )
            try await finishInstall(admission)
        } catch {
            extensionMessage = "Installation failed: \(describeExtensionError(error))"
        }
    }

    func cancelInstall(_ preparation: ExtensionInstallPreparation) {
        pendingExtensionTrust = nil
        Task { await installationService.cancel(preparation) }
    }

    func setExtensionEnabled(_ enabled: Bool, packageName: String) async {
        guard let installed = installedExtension(packageName: packageName),
              !extensionBusyPackages.contains(packageName) else { return }
        extensionBusyPackages.insert(packageName)
        extensionMessage = nil
        defer { extensionBusyPackages.remove(packageName) }

        do {
            if enabled {
                try await store.setExtensionEnabled(true, packageName: packageName)
                do {
                    try await activateExtension(packageName: packageName)
                } catch {
                    try? await store.setExtensionEnabled(false, packageName: packageName)
                    throw error
                }
            } else {
                try await store.setExtensionEnabled(false, packageName: packageName)
                registry.removeDownloaded(
                    sourceIDs: installed.sourceIDs,
                    packageName: installed.packageName
                )
                sourceGeneration &+= 1
            }
            await reloadInstalledExtensions()
        } catch {
            extensionMessage = "Could not \(enabled ? "enable" : "disable") extension: \(describeExtensionError(error))"
            await reloadInstalledExtensions()
        }
    }

    private func restoreInstalledExtensions() async {
        await reloadInstalledExtensions()
        var failures: [String] = []
        for installed in installedExtensions where installed.enabled {
            do {
                try await activateExtension(packageName: installed.packageName)
            } catch {
                try? await store.setExtensionEnabled(
                    false,
                    packageName: installed.packageName
                )
                failures.append(installed.packageName)
            }
        }
        await reloadInstalledExtensions()
        if !failures.isEmpty {
            extensionMessage = "Disabled \(failures.count) extension(s) that could not be authenticated and restored."
        }
    }

    private func finishInstall(_ admission: ExtensionAdmission) async throws {
        guard let installed = try await store.installedExtensionTrust(
            packageName: admission.packageName
        ) else {
            throw ExtensionAdmissionError.extensionNotInstalled(admission.packageName)
        }
        if installed.enabled {
            do {
                try await activateExtension(packageName: admission.packageName)
            } catch {
                try? await store.setExtensionEnabled(
                    false,
                    packageName: admission.packageName
                )
                await reloadInstalledExtensions()
                extensionMessage = "Installed securely but left disabled: \(describeExtensionError(error))"
                return
            }
        }
        await reloadInstalledExtensions()
        extensionMessage = "Installed \(admission.packageName) \(admission.versionName) securely."
    }

    private func activateExtension(packageName: String) async throws {
        let admission = try await admissionService.restore(packageName: packageName)
        let factory = sourceFactory
        let sources = try await Task.detached(priority: .userInitiated) {
            try factory.makeSources(admission: admission)
        }.value
        for source in sources {
            try registry.addDownloaded(source, admission: admission)
        }
        sourceGeneration &+= 1
    }

    private func reloadInstalledExtensions() async {
        installedExtensions = (try? await store.installedExtensionTrusts()) ?? []
    }

    private func reloadExtensionRepositories() async {
        guard let records = try? await store.extensionRepositories() else { return }
        var states: [ExtensionRepositoryState] = []
        for record in records {
            do {
                let index = try await storeClient.fetchIndex(record.url)
                let refreshed = try await store.upsertExtensionRepository(
                    url: record.url,
                    name: index.storeName,
                    signingKey: index.signingKey
                )
                states.append(
                    ExtensionRepositoryState(
                        record: refreshed,
                        index: index,
                        loadError: nil
                    )
                )
            } catch {
                states.append(
                    ExtensionRepositoryState(
                        record: record,
                        index: nil,
                        loadError: describeExtensionError(error)
                    )
                )
            }
        }
        extensionRepositories = states
    }

    private func describeExtensionError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    func toggleLibrary(_ manga: Manga) {
        guard let id = manga.id else { return }
        Task {
            try? await store.setLibrary(!manga.inLibrary, mangaId: id)
            reloadLibrary()
        }
    }
}
