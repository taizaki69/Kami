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

enum ExtensionConfigurationSaveError: Error, LocalizedError {
    case busy
    case savedButInactive(snapshot: ExtensionConfigurationSnapshot, message: String)

    var errorDescription: String? {
        switch self {
        case .busy: return "This extension is busy. Please try again when it finishes."
        case let .savedButInactive(_, message):
            return "Your settings were saved, but the source could not be activated. \(message)"
        }
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
    let preferencesService: ExtensionPreferencesService
    let libraryUpdateService: LibraryUpdateService

    @Published private(set) var librarySnapshot = LibrarySnapshot()
    @Published private(set) var libraryError: String?
    @Published var loading = false
    @Published private(set) var installedExtensions: [InstalledExtensionTrust] = []
    @Published private(set) var extensionBusyPackages = Set<String>()
    @Published var pendingExtensionTrust: ExtensionInstallPreparation?
    @Published var extensionMessage: String?
    @Published private(set) var sourceGeneration: UInt64 = 0
    @Published private(set) var extensionRepositories: [ExtensionRepositoryState] = []
    @Published private(set) var extensionConfigurations: [String: ExtensionConfigurationSnapshot] = [:]
    @Published private(set) var extensionErrors: [String: String] = [:]
    @Published private(set) var libraryUpdatesSnapshot: LibraryUpdatesSnapshot?
    @Published private(set) var libraryUpdatesLoading = false
    @Published private(set) var libraryUpdatesError: String?
    @Published private(set) var libraryUpdateGroups: [LibraryUpdateChapterGroup] = []
    @Published private(set) var libraryUpdatesHasMore = false
    @Published private(set) var libraryUpdatesLoadingMore = false
    @Published private(set) var libraryUpdatesPaginationError: String?
    @Published private(set) var libraryUpdateProgress: LibraryUpdateProgress?
    @Published private(set) var libraryUpdateIsRunning = false
    @Published private(set) var libraryUpdateIsCancelling = false
    private var libraryUpdatesReloadGeneration: UInt64 = 0
    private var libraryUpdateTask: Task<Void, Never>?
    private var libraryUpdateDiscoveries: [LibraryChapterDiscovery] = []
    private var libraryUpdatesNextCursor: LibraryChapterDiscoveryCursor?
    private var libraryReloadGeneration: UInt64 = 0
    private var extensionsReloadGeneration: UInt64 = 0
    private struct SourceExecutionState {
        let packageName: String
        let revision: UInt64
        let configuration: ExtensionExecutionConfiguration
    }
    private var sourceExecutionStates: [Int64: SourceExecutionState] = [:]

    static let configurableFooPackage = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"

    var library: [Manga] { librarySnapshot.manga }
    var categories: [KamiCore.Category] { librarySnapshot.categories }

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
        self.preferencesService = ExtensionPreferencesService(store: store)
        self.libraryUpdateService = LibraryUpdateService(store: store)
        reloadLibrary()
        Task { [weak self] in
            await self?.restoreInstalledExtensions()
            await self?.reloadExtensionRepositories()
        }
    }

    func reloadLibrary() {
        Task { await refreshLibrary() }
    }

    func refreshLibrary() async {
        libraryReloadGeneration &+= 1
        let generation = libraryReloadGeneration
        loading = true
        defer {
            if generation == libraryReloadGeneration { loading = false }
        }
        do {
            let snapshot = try await store.librarySnapshot()
            guard generation == libraryReloadGeneration, !Task.isCancelled else { return }
            librarySnapshot = snapshot
            libraryError = nil
        } catch {
            guard generation == libraryReloadGeneration, !Task.isCancelled else { return }
            libraryError = "Could not load your library. Please try again."
        }
    }

    func createCategory(name: String) async throws {
        _ = try await store.createCategory(name: name)
        await refreshLibrary()
    }

    func renameCategory(id: Int64, name: String) async throws {
        try await store.renameCategory(id: id, name: name)
        await refreshLibrary()
    }

    func reorderCategories(ids: [Int64]) async throws {
        try await store.reorderCategories(ids: ids)
        await refreshLibrary()
    }

    func deleteCategories(ids: Set<Int64>) async throws {
        try await store.deleteCategories(ids: ids)
        await refreshLibrary()
    }

    func updateCategories(_ draft: CategoryAssignmentDraft) async throws {
        try await store.updateCategories(adding: draft.additions, removing: draft.removals,
                                         mangaIDs: draft.mangaIDs)
        await refreshLibrary()
    }

    func setLibrary(_ inLibrary: Bool, mangaId: Int64) async throws {
        try await store.setLibrary(inLibrary, mangaId: mangaId)
        await refreshLibrary()
    }

    func libraryErrorMessage(for error: Error) -> String {
        (error as? LibraryCategoryError)?.errorDescription
            ?? "Your changes could not be saved. Please try again."
    }

    /// Reading the ledger may recover an interrupted run, but never starts
    /// source requests. The service coalesces this one-time local recovery.
    func refreshLibraryUpdates() async {
        libraryUpdatesReloadGeneration &+= 1
        let generation = libraryUpdatesReloadGeneration
        libraryUpdatesLoading = true
        libraryUpdatesLoadingMore = false
        defer {
            if generation == libraryUpdatesReloadGeneration { libraryUpdatesLoading = false }
        }
        do {
            _ = try await libraryUpdateService.prepare()
            let snapshot = try await store.libraryUpdatesSnapshot()
            guard !Task.isCancelled, generation == libraryUpdatesReloadGeneration else { return }
            libraryUpdatesSnapshot = snapshot
            libraryUpdateDiscoveries = snapshot.discoveries
            libraryUpdateGroups = LibraryUpdateChapterGroup.group(snapshot.discoveries)
            libraryUpdatesHasMore = snapshot.hasMore
            libraryUpdatesNextCursor = snapshot.nextCursor
            libraryUpdatesPaginationError = nil
            libraryUpdatesError = nil
        } catch {
            guard !Task.isCancelled, generation == libraryUpdatesReloadGeneration else { return }
            libraryUpdatesError = "Saved updates could not be loaded. Please try again."
        }
    }

    func checkLibraryForUpdates() async {
        guard libraryUpdateTask == nil else { return }
        libraryUpdateIsRunning = true
        libraryUpdateIsCancelling = false
        libraryUpdateProgress = nil
        libraryUpdatesError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            var scanError: String?
            do {
                // Capture the facade and its configuration token together on
                // MainActor, before the scanner captures its DB targets.
                let contexts = self.libraryUpdateSourceContexts()
                let run = try await self.libraryUpdateService.start(sources: contexts)
                if self.libraryUpdateIsCancelling { await self.libraryUpdateService.cancel() }
                for await progress in run.updates {
                    guard progress.scanID == run.scanID else { continue }
                    self.libraryUpdateProgress = progress
                    if progress.phase == .cancelling { self.libraryUpdateIsCancelling = true }
                    if let error = progress.error { scanError = error.errorDescription }
                }
            } catch {
                scanError = (error as? LibraryUpdateServiceError)?.errorDescription
                    ?? "The library check could not finish. Saved updates have been kept."
            }
            // Keep the local run locked until cooperative cancellation has
            // drained and the stream closes. Navigation never cancels it.
            await self.refreshLibraryUpdates()
            await self.refreshLibrary()
            if let scanError { self.libraryUpdatesError = scanError }
            self.libraryUpdateIsRunning = false
            self.libraryUpdateIsCancelling = false
            self.libraryUpdateTask = nil
        }
        libraryUpdateTask = task
        await task.value
    }

    func loadMoreLibraryUpdates() async {
        guard !libraryUpdatesLoading, !libraryUpdatesLoadingMore, libraryUpdatesHasMore else { return }
        guard let cursor = libraryUpdatesNextCursor else {
            libraryUpdatesPaginationError = "More saved updates could not be loaded. Reload the list and try again."
            return
        }
        let generation = libraryUpdatesReloadGeneration
        libraryUpdatesLoadingMore = true
        defer {
            if generation == libraryUpdatesReloadGeneration { libraryUpdatesLoadingMore = false }
        }
        do {
            let page = try await store.libraryUpdatesSnapshot(after: cursor)
            guard !Task.isCancelled, generation == libraryUpdatesReloadGeneration else { return }
            var seen = Set(libraryUpdateDiscoveries.map(\.id))
            libraryUpdateDiscoveries += page.discoveries.filter { seen.insert($0.id).inserted }
            libraryUpdateGroups = LibraryUpdateChapterGroup.group(libraryUpdateDiscoveries)
            libraryUpdatesHasMore = page.hasMore
            libraryUpdatesNextCursor = page.nextCursor
            libraryUpdatesPaginationError = nil
        } catch {
            guard !Task.isCancelled, generation == libraryUpdatesReloadGeneration else { return }
            libraryUpdatesPaginationError = "More saved updates could not be loaded. Please try again."
        }
    }

    func cancelLibraryUpdate() {
        guard libraryUpdateIsRunning, !libraryUpdateIsCancelling else { return }
        libraryUpdateIsCancelling = true
        Task { await libraryUpdateService.cancel() }
    }

    private func libraryUpdateSourceContexts() -> [Int64: LibraryUpdateSourceContext] {
        var contexts: [Int64: LibraryUpdateSourceContext] = [:]
        for source in sources {
            let revision = sourceRevision(for: source.id)
            do {
                contexts[source.id] = .available(
                    source: source,
                    expectedConfiguration: try sourceExecutionConfiguration(id: source.id, revision: revision)
                )
            } catch {
                // A missing downloaded token must not become native nil.
                contexts[source.id] = .configurationUnavailable
            }
        }
        return contexts
    }

    func source(id: Int64) -> (any KamiSource)? {
        _ = sourceGeneration
        return registry.source(id: id)
    }

    func sourceRevision(for sourceID: Int64) -> UInt64 {
        _ = sourceGeneration
        return registry.revision(for: sourceID)
    }

    func isSourceCurrent(id: Int64, revision: UInt64) -> Bool {
        sourceRevision(for: id) == revision && source(id: id) != nil
    }

    func sourceExecutionConfiguration(id: Int64, revision: UInt64) throws -> ExtensionExecutionConfiguration? {
        guard isSourceCurrent(id: id, revision: revision) else { throw CancellationError() }
        if case .downloadedExtension = registry.origin(of: id) {
            guard let execution = sourceExecutionStates[id], execution.revision == revision else {
                throw ExtensionPreferencesError.staleInstallation
            }
            return execution.configuration
        }
        return nil
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

    func extensionIsActive(_ installed: InstalledExtensionTrust) -> Bool {
        _ = sourceGeneration
        return installed.enabled && installed.sourceIDs.contains {
            registry.origin(of: $0) == .downloadedExtension(packageName: installed.packageName)
                && registry.source(id: $0) != nil
        }
    }

    func extensionNeedsConfiguration(packageName: String) -> Bool {
        guard let snapshot = extensionConfigurations[packageName] else { return false }
        guard case let .string(url)? = snapshot.userValues[.baseURL] else { return true }
        return url.isEmpty
    }

    func extensionStatus(_ installed: InstalledExtensionTrust) -> String {
        if extensionBusyPackages.contains(installed.packageName) { return "Working…" }
        if extensionIsActive(installed) { return "Active" }
        if extensionNeedsConfiguration(packageName: installed.packageName) {
            return "Disabled · source URL required"
        }
        return installed.enabled ? "Inactive · activation needs attention" : "Disabled"
    }

    func extensionConfiguration(packageName: String) async throws -> ExtensionConfigurationSnapshot {
        let snapshot = try await preferencesService.configuration(packageName: packageName)
        try Task.checkCancellation()
        extensionConfigurations[packageName] = snapshot
        return snapshot
    }

    func refreshInstalledExtensions() async {
        await reloadInstalledExtensions()
    }

    func configurationErrorMessage(for error: Error) -> String {
        describeExtensionError(error)
    }

    func saveExtensionConfiguration(
        snapshot: ExtensionConfigurationSnapshot,
        userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value],
        enableAfterSaving: Bool = false
    ) async throws -> ExtensionConfigurationSnapshot {
        let packageName = snapshot.packageName
        guard !extensionBusyPackages.contains(packageName) else {
            throw ExtensionConfigurationSaveError.busy
        }
        extensionBusyPackages.insert(packageName)
        defer { extensionBusyPackages.remove(packageName) }

        // A failed validation or database save leaves the running source alone.
        let saved = try await preferencesService.saveConfiguration(
            snapshot: snapshot,
            userValues: userValues
        )
        extensionConfigurations[packageName] = saved
        extensionErrors.removeValue(forKey: packageName)
        extensionMessage = nil
        if saved.enabled || enableAfterSaving {
            revokeExtension(packageName: packageName)
            do {
                if !saved.enabled {
                    try await store.setExtensionEnabled(true, packageName: packageName)
                }
                try await activateExtension(packageName: packageName)
            } catch {
                let message = await failActivation(packageName: packageName, error: error)
                await reloadInstalledExtensions()
                let current = extensionConfigurations[packageName] ?? saved
                throw ExtensionConfigurationSaveError.savedButInactive(snapshot: current, message: message)
            }
        }
        await reloadInstalledExtensions()
        return extensionConfigurations[packageName] ?? saved
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
            let message = "Installation failed: \(describeExtensionError(error))"
            extensionErrors[packageName] = message
            extensionMessage = message
            await reloadInstalledExtensions()
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
            let message = "Installation failed: \(describeExtensionError(error))"
            extensionErrors[packageName] = message
            extensionMessage = message
            await reloadInstalledExtensions()
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
                    _ = await failActivation(packageName: packageName, error: error)
                    await reloadInstalledExtensions()
                    return
                }
            } else {
                try await store.setExtensionEnabled(false, packageName: packageName)
                revokeExtension(packageName: installed.packageName)
                extensionErrors.removeValue(forKey: packageName)
            }
            await reloadInstalledExtensions()
        } catch {
            let message = "Could not \(enabled ? "enable" : "disable") extension: \(describeExtensionError(error))"
            extensionErrors[packageName] = message
            extensionMessage = message
            await reloadInstalledExtensions()
        }
    }

    private func restoreInstalledExtensions() async {
        await reloadInstalledExtensions()
        for installed in installedExtensions where installed.enabled {
            let packageName = installed.packageName
            guard !extensionBusyPackages.contains(packageName) else { continue }
            extensionBusyPackages.insert(packageName)
            do {
                if try await store.installedExtensionTrust(packageName: packageName)?.enabled == true {
                    try await activateExtension(packageName: packageName)
                }
            } catch {
                _ = await failActivation(packageName: packageName, error: error)
            }
            extensionBusyPackages.remove(packageName)
        }
        await reloadInstalledExtensions()
    }

    private func finishInstall(_ admission: ExtensionAdmission) async throws {
        guard let installed = try await store.installedExtensionTrust(
            packageName: admission.packageName
        ) else {
            throw ExtensionAdmissionError.extensionNotInstalled(admission.packageName)
        }
        if installed.enabled {
            do {
                // Installed bytes have already changed. The old runtime must
                // not survive an update that cannot construct its replacement.
                revokeExtension(packageName: admission.packageName)
                try await activateExtension(packageName: admission.packageName)
            } catch {
                let message = await failActivation(packageName: admission.packageName, error: error)
                await reloadInstalledExtensions()
                extensionMessage = "Installed securely; source is inactive. \(message)"
                return
            }
        } else {
            revokeExtension(packageName: admission.packageName)
        }
        await reloadInstalledExtensions()
        extensionMessage = "Installed \(admission.packageName) \(admission.versionName) securely."
    }

    private func activateExtension(packageName: String) async throws {
        let admission = try await admissionService.restore(packageName: packageName)
        let configuration = try await preferencesService.loadForExecution(admission: admission)
        let factory = sourceFactory
        let construction = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try factory.makeSources(admission: admission, preferences: configuration.runtimePreferences)
        }
        let sources = try await withTaskCancellationHandler {
            try await construction.value
        } onCancel: {
            construction.cancel()
        }
        try Task.checkCancellation()
        try await preferencesService.verifyCurrentExecution(configuration)
        try Task.checkCancellation()
        try registry.replaceDownloaded(sources: sources, admission: admission)
        sourceExecutionStates = sourceExecutionStates.filter { $0.value.packageName != packageName }
        for source in sources {
            sourceExecutionStates[source.id] = SourceExecutionState(
                packageName: packageName,
                revision: registry.revision(for: source.id),
                configuration: configuration
            )
        }
        sourceGeneration &+= 1
        extensionErrors.removeValue(forKey: packageName)
    }

    private func revokeExtension(packageName: String) {
        registry.removeDownloaded(packageName: packageName)
        sourceExecutionStates = sourceExecutionStates.filter { $0.value.packageName != packageName }
        sourceGeneration &+= 1
    }

    private func failActivation(packageName: String, error: Error) async -> String {
        revokeExtension(packageName: packageName)
        var message = describeExtensionError(error)
        do {
            try await store.setExtensionEnabled(false, packageName: packageName)
        } catch {
            message += " The source is inactive, but its disabled setting could not be saved. Try disabling it again."
        }
        extensionErrors[packageName] = message
        extensionMessage = "Source is inactive: \(message)"
        return message
    }

    private func reloadInstalledExtensions() async {
        extensionsReloadGeneration &+= 1
        let generation = extensionsReloadGeneration
        do {
            let installed = try await store.installedExtensionTrusts()
            var configurations: [String: ExtensionConfigurationSnapshot] = [:]
            for record in installed where record.packageName == Self.configurableFooPackage {
                do {
                    configurations[record.packageName] = try await preferencesService.configuration(
                        packageName: record.packageName
                    )
                } catch {
                    if generation == extensionsReloadGeneration {
                        extensionErrors[record.packageName] = describeExtensionError(error)
                    }
                }
            }
            guard generation == extensionsReloadGeneration, !Task.isCancelled else { return }
            installedExtensions = installed
            extensionConfigurations = configurations
        } catch {
            guard generation == extensionsReloadGeneration, !Task.isCancelled else { return }
            extensionMessage = "Installed extensions could not be loaded. Please try again."
        }
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
        return "The extension operation could not be completed. Please try again."
    }

    func toggleLibrary(_ manga: Manga) {
        guard let id = manga.id else { return }
        Task {
            do {
                try await setLibrary(!manga.inLibrary, mangaId: id)
            } catch {
                libraryError = libraryErrorMessage(for: error)
            }
        }
    }
}
