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

struct ChapterDownloadStatus {
    let jobID: UUID
    let state: DownloadState
    let reason: DownloadFailureReason?
}

struct LibraryPresentationState: Equatable {
    let generation: LibraryPresentationGeneration
    let isExclusive: Bool
}

struct LibraryRestoreFailure: Identifiable {
    let id = UUID()
    let previewID: UUID
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    let readerDisplay = ReaderDisplayController()
    let store: LibraryStore
    let registry: SourceRegistry
    let storeClient: ExtensionStoreClient
    let admissionService: ExtensionAdmissionService
    let installationService: ExtensionInstallationService
    let sourceFactory: ExtensionSourceFactory
    let preferencesService: ExtensionPreferencesService
    let libraryUpdateService: LibraryUpdateService
    let readingStateWriter: ReadingStateWriter
    let libraryOperations: LibraryOperationCoordinator
    private let sourceDiscoveryStore: SourceDiscoveryStore
    @Published private(set) var sourceDiscovery: SourceDiscoveryState
    @Published private(set) var libraryPresentation: LibraryPresentationState
    @Published var libraryOperationError: String?
    @Published var libraryRestoreNotice: String?
    @Published private(set) var libraryRestoreFailure: LibraryRestoreFailure?
    private var libraryRestoreTask: Task<LibraryRestoreCompletion, Error>?
    @Published private(set) var sourceMigrationFailure: LibraryRestoreFailure?
    private var sourceMigrationTask: Task<SourceMigrationCompletion, Error>?
    private let durableDatabaseAvailable: Bool
    private let downloadContentStore: DownloadContentStore?
    private var downloadService: LibraryDownloadService?

    @Published private(set) var librarySnapshot = LibrarySnapshot()
    @Published private(set) var libraryError: String?
    @Published private(set) var readingWriteFailures: [ReadingStateWriteFailure] = []
    @Published private(set) var discardedReadingWriteFailures = 0
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
    @Published private(set) var downloads: [DownloadItem] = []
    @Published private(set) var downloadsSummary: DownloadQueueSummary?
    @Published private(set) var downloadsLoading = false
    @Published private(set) var downloadsError: String?
    @Published private(set) var downloadsHasMore = false
    @Published private(set) var downloadsLoadingMore = false
    @Published private(set) var downloadsPaginationError: String?
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published private(set) var downloadQueueIsRunning = false
    @Published private(set) var downloadQueueIsPausing = false
    @Published private(set) var downloadBusyJobs = Set<UUID>()
    @Published private(set) var downloadBusyChapters = Set<Int64>()
    @Published private(set) var downloadCancellingJobs = Set<UUID>()
    @Published private(set) var downloadOperationErrors: [Int64: String] = [:]
    @Published private(set) var downloadedChapterCounts: [Int64: Int] = [:]
    @Published private var downloadStates: [Int64: ChapterDownloadStatus] = [:]
    private var downloadsReloadGeneration: UInt64 = 0
    private var downloadsNextCursor: DownloadQueueCursor?
    private var downloadTask: Task<Void, Never>?
    private var downloadRunOperation: LibraryOperationLease?
    private var downloadsForegroundActive = true
    private var activeDownloadScenes = Set<UUID>()
    private var downloadCountsGeneration: UInt64 = 0
    private var downloadChapterGenerations: [Int64: UInt64] = [:]
    private var downloadMangaByChapter: [Int64: Int64] = [:]
    private var libraryUpdatesReloadGeneration: UInt64 = 0
    private var libraryUpdateTask: Task<Void, Never>?
    private var libraryUpdateOperation: LibraryOperationLease?
    private var pendingTrustOperation: (id: UUID, lease: LibraryOperationLease)?
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

        let persistentStore = try? LibraryStore(path: dbPath)
        let store = persistentStore ?? (try! LibraryStore(inMemory: true))
        let storeClient = ExtensionStoreClient()
        let admissionService = ExtensionAdmissionService(store: store)
        self.store = store
        self.durableDatabaseAvailable = persistentStore != nil
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
        let discovery = SourceDiscoveryStore(fileURL: url.appendingPathComponent("source-selection.json"))
        self.sourceDiscoveryStore = discovery
        self.sourceDiscovery = discovery.state
        self.libraryUpdateService = LibraryUpdateService(store: store)
        let operations = LibraryOperationCoordinator()
        self.libraryOperations = operations
        self.libraryPresentation = .init(generation: operations.state.presentation, isExclusive: false)
        self.readingStateWriter = ReadingStateWriter(store: store, operationCoordinator: operations)
        if persistentStore != nil {
            do {
                self.downloadContentStore = try DownloadContentStore(root: url.appendingPathComponent("Downloads", isDirectory: true))
            } catch {
                self.downloadContentStore = nil
                self.downloadsError = "Downloads are unavailable. Please try reopening the app after checking device storage."
            }
        } else {
            self.downloadContentStore = nil
            self.downloadsError = "Saved storage could not be opened. Downloaded files have been preserved. Reopen the app to try again."
        }
        if let content = downloadContentStore {
            self.downloadService = LibraryDownloadService(store: store, contentStore: content) { [weak self] sourceID in
                await self?.downloadSourceContext(sourceID: sourceID) ?? .unavailable
            }
        }
        readingStateWriter.onFailuresChanged = { [weak self] failures in
            guard let self else { return }
            self.readingWriteFailures = failures
            self.discardedReadingWriteFailures = self.readingStateWriter.discardedFailureCount
        }
        operations.onStateChanged = { [weak self] state in self?.acceptOperationState(state) }
        discovery.onChange = { [weak self] state in self?.sourceDiscovery = state }
        reloadLibrary()
        performLibraryOperation { [weak self] in
            await self?.restoreInstalledExtensions()
            await self?.reloadExtensionRepositories()
            await self?.refreshDownloads()
        }
    }

    func reloadLibrary() {
        performLibraryOperation { await self.refreshLibrary() }
    }

    /// Reserve synchronously before scheduling. The worker owns its lease;
    /// cancelling its observer requests cancellation but waits for drainage.
    @discardableResult
    func performLibraryOperation(
        expected: LibraryPresentationGeneration? = nil,
        lease: LibraryOperationLease? = nil,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        do {
            let worker: Task<Void, Error>
            if let lease {
                if let expected, expected != lease.presentation { throw LibraryOperationError.stalePresentation }
                worker = try lease.start(operation)
            }
            else { worker = try libraryOperations.start(expected: expected ?? libraryPresentation.generation, operation) }
            return Task { @MainActor in
                await withTaskCancellationHandler {
                    do { try await worker.value }
                    catch is CancellationError {}
                    catch { self.libraryOperationError = error.localizedDescription }
                } onCancel: { worker.cancel() }
            }
        } catch {
            libraryOperationError = error.localizedDescription
            return nil
        }
    }

    /// SwiftUI owns lifecycle Task creation. Its closure must pass the
    /// presentation captured by that view, before any lifecycle suspension.
    func runLibraryOperation(
        expected: LibraryPresentationGeneration,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        guard let worker = performLibraryOperation(expected: expected, operation) else { return }
        await withTaskCancellationHandler {
            if Task.isCancelled { worker.cancel() }
            await worker.value
        } onCancel: { worker.cancel() }
    }

    private func requireLibraryOperation() throws {
        try libraryOperations.validateCurrentOperation()
    }

    private func acceptsLibraryOperation() -> Bool {
        do { try requireLibraryOperation(); return true }
        catch { libraryOperationError = error.localizedDescription; return false }
    }

    private func reserveLibraryLifetime() -> LibraryOperationLease? {
        do {
            try requireLibraryOperation()
            return try libraryOperations.open(expected: libraryPresentation.generation)
        } catch {
            libraryOperationError = error.localizedDescription
            return nil
        }
    }

    private func acceptOperationState(_ state: LibraryOperationState) {
        if state.presentation != libraryPresentation.generation {
            // Clear all cached domain presentation before exposing the new
            // generation to every WindowGroup scene. Registry trust is separate.
            libraryReloadGeneration &+= 1
            libraryUpdatesReloadGeneration &+= 1
            downloadsReloadGeneration &+= 1
            downloadCountsGeneration &+= 1
            librarySnapshot = LibrarySnapshot()
            libraryUpdatesSnapshot = nil
            libraryUpdateDiscoveries = []
            libraryUpdateGroups = []
            libraryUpdatesNextCursor = nil
            libraryUpdatesHasMore = false
            libraryUpdatesLoading = false
            libraryUpdatesLoadingMore = false
            libraryUpdatesPaginationError = nil
            libraryUpdateProgress = nil
            downloads = []
            downloadsSummary = nil
            downloadsNextCursor = nil
            downloadsHasMore = false
            downloadsLoading = false
            downloadsLoadingMore = false
            downloadsPaginationError = nil
            downloadProgress = nil
            downloadedChapterCounts = [:]
            downloadStates = [:]
            downloadMangaByChapter = [:]
            downloadChapterGenerations = [:]
            downloadOperationErrors = [:]
            libraryError = nil
            libraryUpdatesError = nil
            downloadsError = nil
            libraryOperationError = nil
        }
        let next = LibraryPresentationState(generation: state.presentation, isExclusive: state.isExclusive)
        if next != libraryPresentation { libraryPresentation = next }
    }

    func waitForReadingSaves() async {
        let frontier = readingStateWriter.captureFrontier()
        await frontier.wait()
    }

    func prepareLibraryBackup() async throws -> PreparedLibraryBackup {
        try requireLibraryOperation()
        guard durableDatabaseAvailable else { throw LibraryBackupExportError.storageUnavailable }
        try Task.checkCancellation()
        let store = self.store
        let worker = Task.detached(priority: .userInitiated) {
            let document = try await store.exportBackupSnapshot(exportedAt: Int64(Date().timeIntervalSince1970))
            let bytes = try LibraryBackupCodec().encode(document)
            try Task.checkCancellation()
            return PreparedLibraryBackup(document: document, data: bytes)
        }
        return try await withTaskCancellationHandler {
            let backup = try await worker.value
            try Task.checkCancellation()
            return backup
        } onCancel: {
            worker.cancel()
        }
    }

    func readLibraryRestoreFile(_ url: URL, mihon: Bool = false) async throws -> Data {
        try requireLibraryOperation()
        let worker = Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let limit = mihon ? TachibkReader.Policy.default.maximumInputBytes : LibraryBackupPolicy.default.maximumInputBytes
            return try LibraryBackupFileReader.read(url, policy: LibraryBackupPolicy(maximumInputBytes: limit))
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            return data
        } onCancel: { worker.cancel() }
    }

    func previewLibraryRestore(_ data: Data, excludeConflicts: Bool, mihon: Bool = false,
                               acknowledgesLimitations: Bool = false) async throws -> LibraryRestorePreview {
        try requireLibraryOperation()
        guard durableDatabaseAvailable else { throw LibraryRestoreError.storageUnavailable }
        let store = self.store
        let worker = Task.detached(priority: .userInitiated) {
            if mihon {
                return try await store.previewMihonRestore(from: data, acknowledgingLimitations: acknowledgesLimitations)
            }
            return try await store.previewLibraryRestore(from: data, excludingConflictedSources: excludeConflicts)
        }
        return try await withTaskCancellationHandler {
            let preview = try await worker.value
            try Task.checkCancellation()
            return preview
        } onCancel: { worker.cancel() }
    }

    /// Reserve exclusion synchronously, outside an ordinary operation. AppModel
    /// owns the worker through commit/publication even when the old sheet closes.
    func beginLibraryRestore(_ preview: LibraryRestorePreview, expected: LibraryPresentationGeneration) throws {
        guard durableDatabaseAvailable else { throw LibraryRestoreError.storageUnavailable }
        guard libraryRestoreTask == nil else { throw LibraryOperationError.exclusiveInProgress }
        let operation = try libraryOperations.startLibraryRestore(store: store, preview: preview, expected: expected)
        libraryRestoreTask = operation
        libraryRestoreNotice = nil
        libraryRestoreFailure = nil
        Task { @MainActor in
            do {
                let completion = try await operation.value
                let report = completion.report
                libraryRestoreNotice = "Backup restored: \(report.summary.newManga) new manga, \(report.summary.existingManga) existing manga merged."
                if let mapped = preview.mihonReport {
                    libraryRestoreNotice = "Mihon import saved: \(report.summary.restoredManga) supported manga. Excluded: \(mapped.excludedManga) manga, \(mapped.excludedChapters) chapters and \(mapped.excludedHistory) history entries. Keep your original file for data not imported."
                }
                if !completion.presentationPublished {
                    libraryOperationError = "The backup was restored. Reopen the library to refresh its display."
                }
            } catch is CancellationError {
                libraryRestoreNotice = "Restore cancelled. Your library was kept unchanged."
                libraryRestoreFailure = .init(previewID: preview.id, message: "Restore cancelled. Review the backup again before restoring.")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "The backup could not be restored. Your library was kept unchanged."
                libraryRestoreFailure = .init(previewID: preview.id, message: message)
                libraryRestoreNotice = message
            }
            libraryRestoreTask = nil
        }
    }

    func cancelLibraryRestore() { libraryRestoreTask?.cancel() }

    func cancelExclusiveLibraryChange() {
        libraryRestoreTask?.cancel()
        sourceMigrationTask?.cancel()
    }

    func prepareSourceMigration(origin: MangaReadingSnapshot, match: GlobalSearchMatch,
                                registration: SourceRegistrationSnapshot,
                                selection: SourceDiscoverySelectionSnapshot) async throws -> SourceMigrationPreview {
        try requireLibraryOperation()
        guard durableDatabaseAvailable else { throw SourceMigrationError.storageUnavailable }
        guard readySourceRegistrations().contains(where: { $0.registrationID == registration.registrationID })
        else { throw SourceMigrationError.sourceChanged }
        await waitForReadingSaves()
        let configuration = try sourceExecutionConfiguration(id: registration.sourceID, revision: registration.revision)
        try await store.validateSourceExecution(sourceID: registration.sourceID,
            expectedConfiguration: configuration, context: origin.mutationContext)
        let store = self.store
        let worker = Task.detached(priority: .userInitiated) {
            let destination = try await SourceMigrationCandidate.fetch(registration: registration, manga: match.manga, selection: selection)
            return try await store.previewSourceMigration(origin: origin, destination: destination,
                expectedConfiguration: configuration)
        }
        return try await withTaskCancellationHandler {
            let preview = try await worker.value
            try Task.checkCancellation()
            try requireLibraryOperation()
            guard readySourceRegistrations().contains(where: { $0.registrationID == registration.registrationID })
            else { throw SourceMigrationError.sourceChanged }
            return preview
        } onCancel: { worker.cancel() }
    }

    func beginSourceMigration(_ preview: SourceMigrationPreview, selectedMatches: Set<Int>,
                              copyCategories: Bool, expected: LibraryPresentationGeneration) throws {
        guard durableDatabaseAvailable else { throw SourceMigrationError.storageUnavailable }
        guard sourceMigrationTask == nil else { throw LibraryOperationError.exclusiveInProgress }
        let operation = try libraryOperations.startSourceMigration(store: store, preview: preview,
            selectedMatches: selectedMatches, copyCategories: copyCategories, expected: expected)
        sourceMigrationTask = operation
        sourceMigrationFailure = nil
        libraryRestoreNotice = nil
        Task { @MainActor in
            do {
                let completion = try await operation.value
                libraryRestoreNotice = "Destination saved with \(completion.report.selectedChapters) selected chapter matches. Your original manga and downloads are still in the library."
                if !completion.presentationPublished {
                    libraryOperationError = "Migration was saved. Reopen the library to refresh its display."
                }
            } catch {
                let message = error is CancellationError ? "Migration cancelled. Your library was kept unchanged."
                    : (error as? SourceMigrationError)?.errorDescription
                        ?? "Migration could not finish. Your library was kept unchanged. Prepare a new preview."
                sourceMigrationFailure = .init(previewID: preview.id, message: message)
                libraryRestoreNotice = message
            }
            sourceMigrationTask = nil
        }
    }

    func refreshLibrary() async {
        guard acceptsLibraryOperation() else { return }
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

    func createCategory(name: String, context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        _ = try await store.createCategory(name: name, context: context)
        await refreshLibrary()
    }

    func renameCategory(id: Int64, name: String, context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        try await store.renameCategory(id: id, name: name, context: context)
        await refreshLibrary()
    }

    func reorderCategories(ids: [Int64], context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        try await store.reorderCategories(ids: ids, context: context)
        await refreshLibrary()
    }

    func deleteCategories(ids: Set<Int64>, context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        try await store.deleteCategories(ids: ids, context: context)
        await refreshLibrary()
    }

    func updateCategories(_ draft: CategoryAssignmentDraft, context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        try await store.updateCategories(adding: draft.additions, removing: draft.removals,
                                         mangaIDs: draft.mangaIDs, context: context)
        await refreshLibrary()
    }

    func setLibrary(_ inLibrary: Bool, mangaId: Int64, context: LibraryMutationContext) async throws {
        try requireLibraryOperation()
        try await store.setLibrary(inLibrary, mangaId: mangaId, context: context)
        await refreshLibrary()
        await refreshDownloadCounts()
        await refreshDownloadAvailability(mangaID: mangaId)
        await refreshDownloads(preservingLoadedRows: true)
    }

    func libraryErrorMessage(for error: Error) -> String {
        (error as? LibraryMutationError)?.errorDescription
            ?? (error as? LibraryCategoryError)?.errorDescription
            ?? "Your changes could not be saved. Please try again."
    }

    /// Reading the ledger may recover an interrupted run, but never starts
    /// source requests. The service coalesces this one-time local recovery.
    func refreshLibraryUpdates() async {
        guard acceptsLibraryOperation() else { return }
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
            await refreshDownloadAvailability(chapterIDs: snapshot.discoveries.compactMap { $0.chapter.id })
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
        guard acceptsLibraryOperation() else { return }
        guard libraryUpdateTask == nil else { return }
        guard let operation = reserveLibraryLifetime() else { return }
        libraryUpdateOperation = operation
        libraryUpdateIsRunning = true
        libraryUpdateIsCancelling = false
        libraryUpdateProgress = nil
        libraryUpdatesError = nil
        let task = performLibraryOperation(lease: operation) { [weak self] in
            defer { operation.close() }
            guard let self else { return }
            defer { self.libraryUpdateOperation = nil }
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
        if task == nil {
            operation.close()
            libraryUpdateOperation = nil
            libraryUpdateIsRunning = false
        }
        await task?.value
    }

    func loadMoreLibraryUpdates() async {
        guard acceptsLibraryOperation() else { return }
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
            await refreshDownloadAvailability(chapterIDs: page.discoveries.compactMap { $0.chapter.id })
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
        if performLibraryOperation(lease: libraryUpdateOperation, {
            await self.libraryUpdateService.cancel()
        }) == nil { libraryUpdateIsCancelling = false }
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

    func downloadState(for chapterID: Int64) -> ChapterDownloadStatus? { downloadStates[chapterID] }

    func isChapterDownloaded(_ chapterID: Int64) -> Bool { downloadStates[chapterID]?.state == .finished }

    func refreshDownloadCounts() async {
        guard acceptsLibraryOperation() else { return }
        guard durableDatabaseAvailable else { return }
        downloadCountsGeneration &+= 1
        let generation = downloadCountsGeneration
        do {
            let counts = try await store.downloadedChapterCountsByManga()
            guard !Task.isCancelled, generation == downloadCountsGeneration else { return }
            downloadedChapterCounts = counts
        } catch {
            guard !Task.isCancelled, generation == downloadCountsGeneration else { return }
            downloadsError = "Saved download information could not be loaded. Please try again."
        }
    }

    func refreshDownloadAvailability(chapterIDs: [Int64]) async {
        guard acceptsLibraryOperation() else { return }
        guard durableDatabaseAvailable else { return }
        let ids = Array(Set(chapterIDs)).sorted()
        do {
            for start in stride(from: 0, to: ids.count, by: 500) {
                let batch = Array(ids[start..<min(start + 500, ids.count)])
                let generations = Dictionary(uniqueKeysWithValues: batch.map { ($0, downloadChapterGenerations[$0, default: 0]) })
                let states = try await store.downloadChapterStates(chapterIDs: batch)
                guard !Task.isCancelled else { return }
                for id in batch where downloadChapterGenerations[id, default: 0] == (generations[id] ?? 0) {
                    downloadStates[id] = states[id].map {
                        ChapterDownloadStatus(jobID: $0.jobID, state: $0.state, reason: $0.reason)
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            downloadsError = "Saved download information could not be loaded. Please try again."
        }
    }

    func refreshDownloadAvailability(mangaID: Int64) async {
        guard acceptsLibraryOperation() else { return }
        guard durableDatabaseAvailable else { return }
        let generations = downloadChapterGenerations
        do {
            let states = try await store.downloadChapterStates(mangaID: mangaID)
            guard !Task.isCancelled else { return }
            for (chapterID, state) in states where downloadChapterGenerations[chapterID, default: 0] == (generations[chapterID] ?? 0) {
                downloadMangaByChapter[chapterID] = mangaID
                downloadStates[chapterID] = ChapterDownloadStatus(jobID: state.jobID, state: state.state, reason: state.reason)
            }
            for (chapterID, parentID) in downloadMangaByChapter where parentID == mangaID && states[chapterID] == nil
                && downloadChapterGenerations[chapterID, default: 0] == (generations[chapterID] ?? 0) {
                downloadStates.removeValue(forKey: chapterID)
            }
        } catch {
            guard !Task.isCancelled else { return }
            downloadsError = "Saved download information could not be loaded. Please try again."
        }
    }

    /// Recovery and cleanup only. Opening Downloads never starts transfers.
    func refreshDownloads(preservingLoadedRows: Bool = false) async {
        guard acceptsLibraryOperation() else { return }
        guard let service = downloadService else { return }
        downloadsReloadGeneration &+= 1
        let generation = downloadsReloadGeneration
        downloadsLoading = true
        downloadsLoadingMore = false
        defer { if generation == downloadsReloadGeneration { downloadsLoading = false } }
        do {
            try await service.prepare()
            let desiredCount = preservingLoadedRows ? max(100, downloads.count) : 100
            var snapshot = try await store.downloadsSnapshot()
            var items = snapshot.items
            while snapshot.hasMore && items.count < desiredCount {
                guard !Task.isCancelled, generation == downloadsReloadGeneration else { return }
                guard let cursor = snapshot.nextCursor else { throw DownloadPersistenceError.invalidStoredRecord }
                snapshot = try await store.downloadsSnapshot(limit: min(500, desiredCount - items.count), after: cursor)
                items += snapshot.items
            }
            guard !Task.isCancelled, generation == downloadsReloadGeneration else { return }
            var seen = Set<UUID>()
            downloads = items.filter { seen.insert($0.jobID).inserted }
            downloadsSummary = snapshot.summary
            downloadsHasMore = snapshot.hasMore
            downloadsNextCursor = snapshot.nextCursor
            downloadsPaginationError = nil
            downloadsError = nil
            for item in downloads { applyDownloadItem(item) }
            await refreshDownloadAvailability(chapterIDs: Array(downloadStates.keys))
            await refreshDownloadCounts()
        } catch {
            guard !Task.isCancelled, generation == downloadsReloadGeneration else { return }
            downloadsError = downloadErrorMessage(error)
        }
    }

    func loadMoreDownloads() async {
        guard acceptsLibraryOperation() else { return }
        guard !downloadsLoading, !downloadsLoadingMore, downloadsHasMore else { return }
        guard let cursor = downloadsNextCursor else {
            downloadsPaginationError = "More downloads could not be loaded. Reload the list and try again."
            return
        }
        let generation = downloadsReloadGeneration
        downloadsLoadingMore = true
        defer { if generation == downloadsReloadGeneration { downloadsLoadingMore = false } }
        do {
            let snapshot = try await store.downloadsSnapshot(after: cursor)
            guard !Task.isCancelled, generation == downloadsReloadGeneration else { return }
            var seen = Set(downloads.map(\.jobID))
            downloads += snapshot.items.filter { seen.insert($0.jobID).inserted }
            downloadsSummary = snapshot.summary
            downloadsHasMore = snapshot.hasMore
            downloadsNextCursor = snapshot.nextCursor
            downloadsPaginationError = nil
            for item in snapshot.items { applyDownloadItem(item) }
        } catch {
            guard !Task.isCancelled, generation == downloadsReloadGeneration else { return }
            downloadsPaginationError = "More downloads could not be loaded. Please try again."
        }
    }

    func enqueueDownload(chapterID: Int64) async {
        guard acceptsLibraryOperation() else { return }
        guard !downloadBusyChapters.contains(chapterID) else { return }
        downloadBusyChapters.insert(chapterID)
        downloadOperationErrors.removeValue(forKey: chapterID)
        defer { downloadBusyChapters.remove(chapterID) }
        do {
            guard let service = downloadService else { throw LibraryDownloadServiceError.storageUnavailable }
            let item = try await service.enqueue(chapterID: chapterID)
            applyDownloadItem(item)
            await refreshDownloads(preservingLoadedRows: true)
            await startDownloads()
        } catch {
            downloadOperationErrors[chapterID] = downloadErrorMessage(error)
        }
    }

    func retryDownload(jobID: UUID) async {
        guard acceptsLibraryOperation() else { return }
        guard !downloadBusyJobs.contains(jobID) else { return }
        downloadBusyJobs.insert(jobID)
        defer { downloadBusyJobs.remove(jobID) }
        var chapterID: Int64?
        do {
            chapterID = try await store.downloadItem(jobID: jobID)?.chapter.id
            if let chapterID { downloadOperationErrors.removeValue(forKey: chapterID) }
            guard let service = downloadService else { throw LibraryDownloadServiceError.storageUnavailable }
            let item = try await service.retry(jobID: jobID)
            applyDownloadItem(item)
            await refreshDownloads(preservingLoadedRows: true)
            await startDownloads()
        } catch {
            if let chapterID { downloadOperationErrors[chapterID] = downloadErrorMessage(error) }
            else { downloadsError = downloadErrorMessage(error) }
        }
    }

    func cancelDownload(jobID: UUID) async {
        guard acceptsLibraryOperation() else { return }
        guard !downloadBusyJobs.contains(jobID) else { return }
        downloadBusyJobs.insert(jobID)
        downloadCancellingJobs.insert(jobID)
        defer {
            downloadBusyJobs.remove(jobID)
            downloadCancellingJobs.remove(jobID)
        }
        var chapterID: Int64?
        do {
            chapterID = try await store.downloadItem(jobID: jobID)?.chapter.id
            if let chapterID { downloadOperationErrors.removeValue(forKey: chapterID) }
            guard let service = downloadService else { throw LibraryDownloadServiceError.storageUnavailable }
            if let item = try await service.cancel(jobID: jobID) { applyDownloadItem(item) }
            await refreshDownloads(preservingLoadedRows: true)
        } catch {
            if let chapterID { downloadOperationErrors[chapterID] = downloadErrorMessage(error) }
            else { downloadsError = downloadErrorMessage(error) }
        }
    }

    func deleteDownload(jobID: UUID) async {
        guard acceptsLibraryOperation() else { return }
        guard !downloadBusyJobs.contains(jobID) else { return }
        downloadBusyJobs.insert(jobID)
        defer { downloadBusyJobs.remove(jobID) }
        var chapterID: Int64?
        do {
            chapterID = try await store.downloadItem(jobID: jobID)?.chapter.id
            if let chapterID { downloadOperationErrors.removeValue(forKey: chapterID) }
            guard let service = downloadService else { throw LibraryDownloadServiceError.storageUnavailable }
            if let item = try await service.delete(jobID: jobID) { applyDownloadItem(item) }
            else {
                downloads.removeAll { $0.jobID == jobID }
                if let chapterID {
                    downloadStates.removeValue(forKey: chapterID)
                    downloadChapterGenerations[chapterID, default: 0] &+= 1
                }
            }
            await refreshDownloads(preservingLoadedRows: true)
        } catch {
            if let chapterID { downloadOperationErrors[chapterID] = downloadErrorMessage(error) }
            else { downloadsError = downloadErrorMessage(error) }
        }
    }

    /// Only user actions enqueue/retry/start call this. The task belongs to
    /// AppModel and keeps consuming progress when the screen disappears.
    func startDownloads() async {
        guard acceptsLibraryOperation() else { return }
        guard downloadTask == nil, downloadsForegroundActive, let service = downloadService else { return }
        guard let operation = reserveLibraryLifetime() else { return }
        downloadRunOperation = operation
        downloadQueueIsRunning = true
        downloadQueueIsPausing = false
        downloadsError = nil
        downloadProgress = nil
        downloadTask = performLibraryOperation(lease: operation) { [weak self] in
            defer { operation.close() }
            guard let self else { return }
            defer { self.downloadRunOperation = nil }
            var failure: String?
            do {
                guard self.downloadsForegroundActive, !self.downloadQueueIsPausing else {
                    self.downloadQueueIsRunning = false
                    self.downloadQueueIsPausing = false
                    self.downloadTask = nil
                    return
                }
                let run = try await service.start()
                if self.downloadQueueIsPausing || !self.downloadsForegroundActive {
                    try await service.pause()
                }
                for await progress in run.updates {
                    guard progress.runID == run.id else { continue }
                    self.downloadProgress = progress
                    if let item = progress.item {
                        let prior = self.downloadStates[item.chapter.id ?? 0]?.state
                        self.applyDownloadItem(item)
                        if prior != item.state { await self.refreshDownloads(preservingLoadedRows: true) }
                    }
                    if let error = progress.error { failure = self.downloadErrorMessage(error) }
                }
            } catch {
                failure = self.downloadErrorMessage(error)
            }
            await self.refreshDownloads(preservingLoadedRows: true)
            if let failure { self.downloadsError = failure }
            self.downloadQueueIsRunning = false
            self.downloadQueueIsPausing = false
            self.downloadTask = nil
        }
        if downloadTask == nil {
            operation.close()
            downloadRunOperation = nil
            downloadQueueIsRunning = false
        }
    }

    func pauseDownloads() async {
        guard acceptsLibraryOperation() else { return }
        guard downloadQueueIsRunning, !downloadQueueIsPausing, let service = downloadService else { return }
        downloadQueueIsPausing = true
        do { try await service.pause() }
        catch { downloadsError = downloadErrorMessage(error) }
        await refreshDownloads(preservingLoadedRows: true)
    }

    /// A run's cancellation controls borrow its lifetime so reaching the
    /// global admission limit cannot prevent that run from draining.
    func requestDownloadPause(expected: LibraryPresentationGeneration) {
        performLibraryOperation(expected: expected, lease: downloadRunOperation) {
            await self.pauseDownloads()
        }
    }

    func requestDownloadCancellation(jobID: UUID, expected: LibraryPresentationGeneration) {
        performLibraryOperation(expected: expected, lease: downloadRunOperation) {
            await self.cancelDownload(jobID: jobID)
        }
    }

    func downloadsSceneChanged(sceneID: UUID, active: Bool) {
        if active { activeDownloadScenes.insert(sceneID) }
        else { activeDownloadScenes.remove(sceneID) }
        downloadsForegroundActive = !activeDownloadScenes.isEmpty
        if !downloadsForegroundActive, let operation = downloadRunOperation {
            performLibraryOperation(lease: operation) { await self.pauseDownloads() }
        }
    }

    func openOfflineChapter(target: ChapterWriteTarget) async throws -> OfflineReaderChapter? {
        try requireLibraryOperation()
        guard let service = downloadService else { throw LibraryDownloadServiceError.storageUnavailable }
        _ = try await store.validateReadingTarget(target)
        try await service.prepare()
        guard let bundle = try await store.offlineChapter(chapterID: target.chapterID) else {
            _ = try await store.validateReadingTarget(target)
            return nil
        }
        guard bundle.manga.id == target.mangaID, bundle.manga.sourceId == target.sourceID,
              bundle.chapter.id == target.chapterID, bundle.chapter.mangaId == target.mangaID,
              Data(bundle.manga.url.utf8) == Data(target.mangaURL.utf8),
              Data(bundle.chapter.url.utf8) == Data(target.chapterURL.utf8) else {
            throw ReadingStateError.identityChanged
        }
        let lease = try await service.openOfflineChapter(chapterID: target.chapterID)
        do {
            guard lease.identity == bundle.identity else { throw DownloadPersistenceError.staleAttempt }
            let current = try await store.validateReadingTarget(target)
            try Task.checkCancellation()
            return OfflineReaderChapter(chapter: current, lease: lease)
        } catch {
            await lease.close()
            throw error
        }
    }

    private func applyDownloadItem(_ item: DownloadItem) {
        if let chapterID = item.chapter.id {
            downloadChapterGenerations[chapterID, default: 0] &+= 1
            downloadStates[chapterID] = ChapterDownloadStatus(jobID: item.jobID, state: item.state, reason: item.reason)
            downloadMangaByChapter[chapterID] = item.chapter.mangaId
        }
        if let index = downloads.firstIndex(where: { $0.jobID == item.jobID }) { downloads[index] = item }
    }

    private func downloadSourceContext(sourceID: Int64) -> DownloadSourceContext {
        guard let registration = registry.registrationSnapshot(id: sourceID) else { return .unavailable }
        if case let .downloadedExtension(packageName) = registration.origin,
           extensionBusyPackages.contains(packageName) { return .configurationUnavailable }
        do {
            let configuration = try sourceExecutionConfiguration(id: sourceID, revision: registration.revision)
            try registration.checkAvailability()
            return .available(registration: registration, expectedConfiguration: configuration)
        } catch { return .configurationUnavailable }
    }

    private func downloadErrorMessage(_ error: Error) -> String {
        (error as? LibraryDownloadServiceError)?.errorDescription
            ?? (error as? DownloadPersistenceError)?.errorDescription
            ?? (error as? DownloadContentError)?.errorDescription
            ?? (error as? DownloadImageValidationError)?.errorDescription
            ?? "The download could not finish. Your reading data and completed downloads have been kept."
    }

    func source(id: Int64) -> (any KamiSource)? {
        _ = sourceGeneration
        return registry.source(id: id)
    }

    func sourceRevision(for sourceID: Int64) -> UInt64 {
        _ = sourceGeneration
        return registry.revision(for: sourceID)
    }

    /// Capture only ready published registrations. Busy or unauthenticated
    /// configurations are not an invitation to reconstruct/enable a source.
    func readySourceRegistrations() -> [SourceRegistrationSnapshot] {
        sources.compactMap { source in
            guard case let .available(registration, _) = downloadSourceContext(sourceID: source.id)
            else { return nil }
            return registration
        }
    }

    var discoverySources: [any KamiSource] {
        sources.filter { sourceDiscovery.preferences.includes(sourceID: $0.id, language: $0.language) }
    }

    func sourceDiscoverySnapshot() -> SourceDiscoverySelectionSnapshot { sourceDiscoveryStore.snapshot() }

    func saveSourceDiscovery(_ preferences: SourceDiscoveryPreferences, expectedRevision: UUID) throws {
        try sourceDiscoveryStore.save(preferences, expectedRevision: expectedRevision)
    }

    func prepareCompatibilityReport(registration: SourceRegistrationSnapshot) async throws -> SourceCompatibilityReport {
        try requireLibraryOperation()
        guard readySourceRegistrations().contains(where: { $0.registrationID == registration.registrationID })
        else { throw CancellationError() }
        let report = try await SourceCompatibilityDiagnostics.prepare(registration: registration)
        try requireLibraryOperation()
        try Task.checkCancellation()
        guard readySourceRegistrations().contains(where: { $0.registrationID == registration.registrationID })
        else { throw CancellationError() }
        return report
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
        try requireLibraryOperation()
        let snapshot = try await preferencesService.configuration(packageName: packageName)
        try Task.checkCancellation()
        extensionConfigurations[packageName] = snapshot
        return snapshot
    }

    func refreshInstalledExtensions() async {
        guard acceptsLibraryOperation() else { return }
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
        try requireLibraryOperation()
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
            do {
                if await revokeExtension(packageName: packageName) != nil {
                    throw LibraryDownloadServiceError.storageUnavailable
                }
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
        try requireLibraryOperation()
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
        guard acceptsLibraryOperation() else { return }
        try? await store.removeExtensionRepository(url: url)
        extensionRepositories.removeAll { $0.record.url == url }
    }

    func install(
        extension extensionEntry: ExtensionRepositoryIndex.Extension,
        repositoryURL: String,
        repositorySigningKey: String?
    ) async {
        guard acceptsLibraryOperation() else { return }
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
                guard pendingTrustOperation == nil else {
                    await installationService.cancel(preparation)
                    let message = "Finish the pending signer confirmation before installing another extension."
                    extensionErrors[packageName] = message
                    extensionMessage = message
                    return
                }
                do {
                    let lifetime = try libraryOperations.open(expected: libraryPresentation.generation)
                    pendingTrustOperation = (preparation.id, lifetime)
                } catch {
                    await installationService.cancel(preparation)
                    throw error
                }
                pendingExtensionTrust = preparation
            }
        } catch {
            let message = "Installation failed: \(describeExtensionError(error))"
            extensionErrors[packageName] = message
            extensionMessage = message
            await reloadInstalledExtensions()
        }
    }

    func confirmPendingInstall(_ preparation: ExtensionInstallPreparation, fingerprint: String) {
        guard let pending = pendingTrustOperation, pending.id == preparation.id else { return }
        performLibraryOperation(lease: pending.lease) {
            await self.confirmInstall(preparation, fingerprint: fingerprint)
        }
    }

    private func confirmInstall(
        _ preparation: ExtensionInstallPreparation,
        fingerprint: String
    ) async {
        guard acceptsLibraryOperation() else { return }
        let packageName = preparation.packageName
        guard let pending = pendingTrustOperation, pending.id == preparation.id else { return }
        guard !extensionBusyPackages.contains(packageName) else {
            pendingExtensionTrust = preparation
            extensionMessage = "This extension is busy. Try its signer confirmation after the current operation finishes."
            return
        }
        pendingTrustOperation = nil
        defer { pending.lease.close() }
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
        guard let pending = pendingTrustOperation, pending.id == preparation.id else { return }
        pendingTrustOperation = nil
        pendingExtensionTrust = nil
        performLibraryOperation(lease: pending.lease) { await self.installationService.cancel(preparation) }
        pending.lease.close()
    }

    func setExtensionEnabled(_ enabled: Bool, packageName: String) async {
        guard acceptsLibraryOperation() else { return }
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
                if let warning = await revokeExtension(packageName: installed.packageName) {
                    extensionErrors[packageName] = warning
                    extensionMessage = "The source is disabled. \(warning)"
                } else {
                    extensionErrors.removeValue(forKey: packageName)
                }
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
                if await revokeExtension(packageName: admission.packageName) != nil {
                    throw LibraryDownloadServiceError.storageUnavailable
                }
                try await activateExtension(packageName: admission.packageName)
            } catch {
                let message = await failActivation(packageName: admission.packageName, error: error)
                await reloadInstalledExtensions()
                extensionMessage = "Installed securely; source is inactive. \(message)"
                return
            }
        } else if let warning = await revokeExtension(packageName: admission.packageName) {
            extensionErrors[admission.packageName] = warning
            await reloadInstalledExtensions()
            extensionMessage = "Installed securely; the source is disabled. \(warning)"
            return
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
        let priorSourceIDs = publishedSourceIDs(packageName: packageName)
        if !priorSourceIDs.isEmpty {
            // A fresh restore has no old facade to revoke. Keep its durable
            // queued chapters waiting for the user's explicit Start action.
            try await invalidateDownloadSources(sourceIDs: priorSourceIDs.union(sources.map(\.id)))
            try await preferencesService.verifyCurrentExecution(configuration)
            try Task.checkCancellation()
        }
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

    private func publishedSourceIDs(packageName: String) -> Set<Int64> {
        Set(registry.sources.compactMap { source in
            registry.origin(of: source.id) == .downloadedExtension(packageName: packageName) ? source.id : nil
        }).union(sourceExecutionStates.compactMap { id, execution in
            execution.packageName == packageName ? id : nil
        })
    }

    private func invalidateDownloadSources(sourceIDs: Set<Int64>) async throws {
        guard let service = downloadService, !sourceIDs.isEmpty else { return }
        try await service.invalidateSources(sourceIDs: sourceIDs)
        await refreshDownloads(preservingLoadedRows: true)
    }

    /// Durable invalidation precedes registry revocation. If storage fails,
    /// still revoke the facade and report that download cleanup needs attention.
    private func revokeExtension(packageName: String) async -> String? {
        var warning: String?
        let sourceIDs = publishedSourceIDs(packageName: packageName)
            .union(installedExtension(packageName: packageName)?.sourceIDs ?? [])
        do {
            try await invalidateDownloadSources(sourceIDs: sourceIDs)
        } catch {
            warning = "Pending downloads could not be fully stopped or cleaned up. Open Downloads to retry."
            downloadsError = warning
        }
        registry.removeDownloaded(packageName: packageName)
        sourceExecutionStates = sourceExecutionStates.filter { $0.value.packageName != packageName }
        sourceGeneration &+= 1
        return warning
    }

    private func failActivation(packageName: String, error: Error) async -> String {
        var message = describeExtensionError(error)
        do {
            try await store.setExtensionEnabled(false, packageName: packageName)
        } catch {
            message += " The source is inactive, but its disabled setting could not be saved. Try disabling it again."
        }
        if let warning = await revokeExtension(packageName: packageName) { message += " " + warning }
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

    func toggleLibrary(_ manga: Manga, context: LibraryMutationContext) {
        guard let id = manga.id else { return }
        performLibraryOperation { [self] in
            do {
                try await self.setLibrary(!manga.inLibrary, mangaId: id, context: context)
            } catch {
                libraryError = libraryErrorMessage(for: error)
            }
        }
    }
}
