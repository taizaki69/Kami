import Foundation
import MihonCompatKit

#if canImport(SQLite3)

/// A snapshot of the registration used for this scan. This is not an admission
/// or a way to enable an extension; App captures the registry's revocable facade
/// and its independently authenticated execution configuration.
public enum LibraryUpdateSourceContext: Sendable {
    case available(source: any KamiSource, expectedConfiguration: ExtensionExecutionConfiguration?)
    case unavailable
    case configurationUnavailable
}

public enum LibraryUpdateServiceError: Error, Equatable, Sendable, LocalizedError {
    case alreadyRunning
    case storageUnavailable
    case libraryChanged

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A library update is already running."
        case .storageUnavailable: "The library update could not be stored. Please try again."
        case .libraryChanged: "The library changed during this update. Reload it before checking again."
        }
    }
}

public enum LibraryUpdatePhase: Equatable, Sendable {
    case running, cancelling, finished
}

public struct LibraryUpdateProgress: Equatable, Sendable {
    public let phase: LibraryUpdatePhase
    public let summary: LibraryUpdateSummary
    public let queued: Int
    public let inFlight: Int
    public let error: LibraryUpdateServiceError?
    public var scanID: UUID { summary.scanID }
}

public struct LibraryUpdateRun: Sendable {
    public let scanID: UUID
    /// One latest-value stream per run, owned by AppModel rather than a view.
    /// Dropping a view or stream consumer does not cancel a manual scan.
    public let updates: AsyncStream<LibraryUpdateProgress>
}

/// A narrow deterministic seam for offline coordination tests. The production
/// implementation is LibraryStore; sources never receive this persistence API.
protocol LibraryUpdatePersisting: Sendable {
    func recoverInterruptedLibraryUpdateScans() async throws -> LibraryUpdateSummary?
    func beginLibraryUpdateScan() async throws -> LibraryUpdateScanSnapshot
    func libraryUpdateTargetIsCurrent(scanID: UUID, mangaID: Int64) async throws -> Bool
    func verifyLibraryUpdateSourceConfiguration(
        sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?, context: LibraryMutationContext
    ) async throws
    func recordLibraryUpdateSuccess(
        scanID: UUID, manga: Manga, chapters: [SChapterCompat],
        expectedConfiguration: ExtensionExecutionConfiguration?, context: LibraryMutationContext
    ) async throws -> LibraryUpdateCommitResult
    func recordLibraryUpdateSkip(
        scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason
    ) async throws -> LibraryUpdateSummary
    func recordLibraryUpdateFailure(
        scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason
    ) async throws -> LibraryUpdateSummary
    func finishLibraryUpdateScan(
        scanID: UUID, status: LibraryUpdateScanStatus
    ) async throws -> LibraryUpdateSummary
}

extension LibraryStore: LibraryUpdatePersisting {
    func verifyLibraryUpdateSourceConfiguration(
        sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?, context: LibraryMutationContext
    ) throws {
        try validateSourceExecution(sourceID: sourceID, expectedConfiguration: expectedConfiguration, context: context)
    }
}

/// Manual library updates use a fixed library/registration snapshot. At most
/// three distinct sources run together and manga for one source run in series.
/// Cancellation invalidates the durable scan before draining cooperative work,
/// so an old callback cannot become a new discovery after Cancel.
public actor LibraryUpdateService {
    private struct SourceQueue: Sendable {
        let sourceID: Int64
        let items: [LibraryUpdateItem]
        let source: any KamiSource
        let configuration: ExtensionExecutionConfiguration?
    }

    private struct State {
        let snapshot: LibraryUpdateScanSnapshot
        let sources: [Int64: LibraryUpdateSourceContext]
        let continuation: AsyncStream<LibraryUpdateProgress>.Continuation
        var summary: LibraryUpdateSummary
        var inFlight = Set<Int64>()
        var cancelling = false
        var error: LibraryUpdateServiceError?
        var worker: Task<Void, Never>?
        var termination: Task<LibraryUpdateSummary, Error>?
    }

    private let persistence: any LibraryUpdatePersisting
    private let maximumConcurrentSources: Int
    private var recovery: Task<LibraryUpdateSummary?, Error>?
    private var starting = false
    private var cancelRequestedDuringStart = false
    private var state: State?

    public init(store: LibraryStore, maximumConcurrentSources: Int = 3) {
        self.persistence = store
        self.maximumConcurrentSources = min(3, max(1, maximumConcurrentSources))
    }

    init(persistence: any LibraryUpdatePersisting, maximumConcurrentSources: Int = 3) {
        self.persistence = persistence
        self.maximumConcurrentSources = min(3, max(1, maximumConcurrentSources))
    }

    /// Local recovery only. Concurrent startup readers share this one operation;
    /// a later call cannot interrupt a scan started by this service instance.
    public func prepare() async throws -> LibraryUpdateSummary? {
        if let recovery {
            do { return try await recovery.value }
            catch { throw LibraryUpdateServiceError.storageUnavailable }
        }
        let persistence = persistence
        let task = Task { try await persistence.recoverInterruptedLibraryUpdateScans() }
        recovery = task
        do { return try await task.value }
        catch {
            recovery = nil
            throw LibraryUpdateServiceError.storageUnavailable
        }
    }

    public func start(sources: [Int64: LibraryUpdateSourceContext]) async throws -> LibraryUpdateRun {
        guard !starting, state == nil else { throw LibraryUpdateServiceError.alreadyRunning }
        starting = true
        cancelRequestedDuringStart = false
        defer { starting = false }
        try Task.checkCancellation()
        _ = try await prepare()
        let snapshot: LibraryUpdateScanSnapshot
        do { snapshot = try await persistence.beginLibraryUpdateScan() }
        catch let error as LibraryUpdatePersistenceError where error == .scanAlreadyRunning {
            throw LibraryUpdateServiceError.alreadyRunning
        } catch { throw LibraryUpdateServiceError.storageUnavailable }

        let pair = AsyncStream<LibraryUpdateProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let run = LibraryUpdateRun(scanID: snapshot.record.scanID, updates: pair.stream)
        state = State(snapshot: snapshot, sources: sources, continuation: pair.continuation, summary: snapshot.record)
        emit()
        if cancelRequestedDuringStart || Task.isCancelled {
            await invalidateRun(scanID: run.scanID)
            await finishRun(scanID: run.scanID)
        } else {
            state?.worker = Task { await self.execute(scanID: run.scanID) }
        }
        return run
    }

    /// Also captures Cancel while prepare/begin are suspended, before scanID
    /// has been returned to App. The next start resets this request explicitly.
    public func cancel() async {
        if starting, state == nil {
            cancelRequestedDuringStart = true
            return
        }
        guard let scanID = state?.summary.scanID else { return }
        await invalidateRun(scanID: scanID)
    }

    private func execute(scanID: UUID) async {
        guard let captured = state, captured.summary.scanID == scanID else { return }
        var itemsBySource: [Int64: [LibraryUpdateItem]] = [:]
        for item in captured.snapshot.items {
            guard canWork(scanID) else { break }
            guard let mangaID = item.manga.id else {
                await invalidateRun(scanID: scanID, error: .storageUnavailable)
                break
            }
            if item.manga.updateStrategy == .onlyFetchOnce, item.hasSuccessfulBaseline {
                await recordSkip(scanID: scanID, mangaID: mangaID, reason: .onlyFetchOnce)
                continue
            }
            switch captured.sources[item.manga.sourceId] ?? .unavailable {
            case .unavailable:
                await recordSkip(scanID: scanID, mangaID: mangaID, reason: .sourceUnavailable)
            case .configurationUnavailable:
                await recordSkip(scanID: scanID, mangaID: mangaID, reason: .configurationChanged)
            case let .available(source, _):
                guard source.id == item.manga.sourceId else {
                    await recordSkip(scanID: scanID, mangaID: mangaID, reason: .configurationChanged)
                    continue
                }
                itemsBySource[item.manga.sourceId, default: []].append(item)
            }
        }
        let queues = itemsBySource.keys.sorted().compactMap { id -> SourceQueue? in
            guard case let .available(source, configuration)? = captured.sources[id],
                  let items = itemsBySource[id] else { return nil }
            return SourceQueue(sourceID: id, items: items, source: source, configuration: configuration)
        }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(maximumConcurrentSources, queues.count), canWork(scanID) {
                let queue = queues[next]
                group.addTask { await self.process(queue, scanID: scanID) }
                next += 1
            }
            while await group.next() != nil {
                if canWork(scanID), next < queues.count {
                    let queue = queues[next]
                    group.addTask { await self.process(queue, scanID: scanID) }
                    next += 1
                }
            }
        }
        await finishRun(scanID: scanID)
    }

    private func process(_ queue: SourceQueue, scanID: UUID) async {
        guard let context = state?.snapshot.mutationContext, state?.summary.scanID == scanID else { return }
        var configurationUnavailable = false
        for item in queue.items {
            guard canWork(scanID), let mangaID = item.manga.id else { return }
            if configurationUnavailable {
                await recordSkip(scanID: scanID, mangaID: mangaID, reason: .configurationChanged)
                continue
            }
            do {
                guard try await persistence.libraryUpdateTargetIsCurrent(scanID: scanID, mangaID: mangaID) else {
                    await recordSkip(scanID: scanID, mangaID: mangaID, reason: .removedFromLibrary)
                    continue
                }
                try await persistence.verifyLibraryUpdateSourceConfiguration(
                    sourceID: queue.sourceID, expectedConfiguration: queue.configuration, context: context
                )
            } catch {
                guard canWork(scanID) else { return }
                guard Self.configurationChanged(error) else {
                    await invalidateRun(scanID: scanID, error: Self.persistenceFailure(error))
                    return
                }
                configurationUnavailable = true
                await recordSkip(scanID: scanID, mangaID: mangaID, reason: .configurationChanged)
                continue
            }
            guard canWork(scanID) else { return }
            state?.inFlight.insert(mangaID)
            emit()
            do {
                let input = SMangaCompat(
                    url: item.manga.url, title: item.manga.title, altTitles: item.manga.altTitles,
                    thumbnailURL: item.manga.thumbnailURL, artist: item.manga.artist,
                    author: item.manga.author, status: item.manga.status,
                    description: item.manga.descriptionText, genres: item.manga.genres,
                    updateStrategy: item.manga.updateStrategy
                )
                let update = try await queue.source.getMangaUpdate(manga: input)
                try Task.checkCancellation()
                guard canWork(scanID) else {
                    removeInFlight(mangaID, scanID: scanID)
                    return
                }
                var refreshed = Manga(sourceId: queue.sourceID, from: update.manga)
                refreshed.id = mangaID
                refreshed.inLibrary = item.manga.inLibrary
                refreshed.dateAdded = item.manga.dateAdded
                refreshed.dateUpdated = Int64(Date().timeIntervalSince1970)
                do {
                    let result = try await persistence.recordLibraryUpdateSuccess(
                        scanID: scanID, manga: refreshed, chapters: update.chapters,
                        expectedConfiguration: queue.configuration, context: context
                    )
                    accept(result.summary, scanID: scanID)
                } catch {
                    if canWork(scanID) {
                        if Self.configurationChanged(error) {
                            configurationUnavailable = true
                            await recordFailure(scanID: scanID, mangaID: mangaID, reason: .configurationChanged)
                        } else {
                            // A successful request followed by a failed store
                            // commit is never attributed to the source website.
                            await invalidateRun(scanID: scanID, error: Self.persistenceFailure(error))
                        }
                    }
                }
            } catch {
                if canWork(scanID) {
                    configurationUnavailable = Self.configurationChanged(error)
                    let reason: LibraryUpdateTargetReason = configurationUnavailable ? .configurationChanged : .requestFailed
                    await recordFailure(scanID: scanID, mangaID: mangaID, reason: reason)
                }
            }
            removeInFlight(mangaID, scanID: scanID)
        }
    }

    private static func configurationChanged(_ error: Error) -> Bool {
        if error is CancellationError || error is SourceUpdatePersistenceError { return true }
        if let error = error as? ExtensionPreferencesError {
            return error != .storageUnavailable
        }
        return error as? LibraryUpdatePersistenceError == .sourceIdentityMismatch
    }

    private static func persistenceFailure(_ error: Error) -> LibraryUpdateServiceError {
        if let error = error as? LibraryMutationError, error == .staleEpoch || error == .foreignContext {
            return .libraryChanged
        }
        return .storageUnavailable
    }

    private func recordSkip(scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason) async {
        guard canWork(scanID) else { return }
        do {
            let summary = try await persistence.recordLibraryUpdateSkip(scanID: scanID, mangaID: mangaID, reason: reason)
            accept(summary, scanID: scanID)
            emit()
        } catch {
            guard canWork(scanID) else { return }
            await invalidateRun(scanID: scanID, error: .storageUnavailable)
        }
    }

    private func recordFailure(scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason) async {
        guard canWork(scanID) else { return }
        do {
            let summary = try await persistence.recordLibraryUpdateFailure(scanID: scanID, mangaID: mangaID, reason: reason)
            accept(summary, scanID: scanID)
        } catch {
            guard canWork(scanID) else { return }
            await invalidateRun(scanID: scanID, error: .storageUnavailable)
        }
    }

    private func canWork(_ scanID: UUID) -> Bool {
        state?.summary.scanID == scanID && state?.cancelling == false && !Task.isCancelled
    }

    private func removeInFlight(_ mangaID: Int64, scanID: UUID) {
        guard state?.summary.scanID == scanID else { return }
        state?.inFlight.remove(mangaID)
        emit()
    }

    private func accept(_ summary: LibraryUpdateSummary, scanID: UUID) {
        guard state?.summary.scanID == scanID, let previous = state?.summary else { return }
        // Store calls may resume in a different order. Do not regress counters
        // or replace a terminal cancellation with an older running snapshot.
        guard summary.processedCount >= previous.processedCount,
              previous.status == .running || summary.status != .running else { return }
        state?.summary = summary
    }

    private func emit(phase: LibraryUpdatePhase? = nil) {
        guard let state else { return }
        state.continuation.yield(LibraryUpdateProgress(
            phase: phase ?? (state.cancelling ? .cancelling : .running), summary: state.summary,
            queued: max(0, state.summary.total - state.summary.processedCount - state.inFlight.count),
            inFlight: state.inFlight.count, error: state.error
        ))
    }

    private func terminate(scanID: UUID, status: LibraryUpdateScanStatus) async throws -> LibraryUpdateSummary {
        guard state?.summary.scanID == scanID else { throw LibraryUpdatePersistenceError.scanNotFound }
        if let termination = state?.termination { return try await termination.value }
        let persistence = persistence
        let task = Task { try await persistence.finishLibraryUpdateScan(scanID: scanID, status: status) }
        state?.termination = task
        do { return try await task.value }
        catch {
            if state?.summary.scanID == scanID { state?.termination = nil }
            throw error
        }
    }

    private func invalidateRun(scanID: UUID, error: LibraryUpdateServiceError? = nil) async {
        guard state?.summary.scanID == scanID else { return }
        state?.cancelling = true
        if let error { state?.error = error }
        state?.worker?.cancel()
        emit()
        do {
            let summary = try await terminate(scanID: scanID, status: .cancelled)
            accept(summary, scanID: scanID)
        } catch {
            if state?.summary.scanID == scanID { state?.error = .storageUnavailable }
        }
        emit()
    }

    private func finishRun(scanID: UUID) async {
        guard state?.summary.scanID == scanID else { return }
        do {
            let summary = try await terminate(scanID: scanID, status: state?.cancelling == true ? .cancelled : .completed)
            accept(summary, scanID: scanID)
        } catch {
            await invalidateRun(scanID: scanID, error: .storageUnavailable)
        }
        guard let finished = state, finished.summary.scanID == scanID else { return }
        emit(phase: .finished)
        finished.continuation.finish()
        // The worker has drained, but a transient failure may have prevented
        // both terminal writes. A subsequent explicit prepare/start can now
        // recover that durable orphan as interrupted instead of staying busy.
        if finished.summary.status == .running { recovery = nil }
        state = nil
    }
}

#endif
