import Foundation
import MihonCompatKit

#if canImport(SQLite3)

/// A current registry publication and its independently authenticated DB
/// configuration. This context cannot enable or admit a source.
public enum DownloadSourceContext: Sendable {
    case available(registration: SourceRegistrationSnapshot,
                   expectedConfiguration: ExtensionExecutionConfiguration?)
    case unavailable
    case configurationUnavailable
}

public enum LibraryDownloadServiceError: Error, Equatable, Sendable, LocalizedError {
    case alreadyRunning, sourceUnavailable, configurationUnavailable
    case storageUnavailable, localChapterUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A download queue is already running."
        case .sourceUnavailable: "Enable an admitted source before starting this download."
        case .configurationUnavailable: "The download source configuration is unavailable."
        case .storageUnavailable: "Download storage is unavailable. Please try again."
        case .localChapterUnavailable: "This chapter has no complete, verified local download."
        }
    }
}

public enum DownloadPhase: Equatable, Sendable { case running, cancelling, finished }

public struct DownloadProgress: Equatable, Sendable {
    public let runID: UUID
    public let phase: DownloadPhase
    public let activeJobID: UUID?
    public let cancellingJobID: UUID?
    public let item: DownloadItem?
    public let error: LibraryDownloadServiceError?
}

public struct DownloadRun: Sendable {
    public let id: UUID
    public let updates: AsyncStream<DownloadProgress>
}

/// A foreground, explicitly started queue. One chapter and one page execute
/// at a time. Each attempt obtains a fresh revocable registration; no source
/// request, headers, cookies or execution handle are persisted for replay.
public actor LibraryDownloadService {
    private struct Failure: Error {
        let reason: DownloadFailureReason
        var stopsQueue = false
    }

    private struct Context {
        let registration: SourceRegistrationSnapshot
        let configuration: ExtensionExecutionConfiguration?
    }

    private struct State {
        let id: UUID
        let continuation: AsyncStream<DownloadProgress>.Continuation
        var worker: Task<Void, Never>?
        var operation: Task<Void, Never>?
        var activeJobID: UUID?
        var attempt: DownloadAttempt?
        var item: DownloadItem?
        var stopRequested = false
        var cancellingJobID: UUID?
        var error: LibraryDownloadServiceError?
    }

    private enum Action: Equatable { case pause, cancel, delete, invalidate(Set<Int64>) }
    private struct Control {
        let id: UUID
        let action: Action
        let task: Task<DownloadItem?, Error>
    }
    private struct Preparation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let store: LibraryStore
    private let contentStore: DownloadContentStore
    private let sourceProvider: @Sendable (Int64) async -> DownloadSourceContext
    private let pipeline: ReaderImagePipeline
    private var preparation: Preparation?
    private var state: State?
    private var controls: [UUID: Control] = [:]
    private var invalidatingSources: [Int64: Int] = [:]

    public init(
        store: LibraryStore, contentStore: DownloadContentStore,
        sourceProvider: @escaping @Sendable (Int64) async -> DownloadSourceContext
    ) {
        self.store = store
        self.contentStore = contentStore
        self.sourceProvider = sourceProvider
        self.pipeline = ReaderImagePipeline(
            sourceID: "downloads", maximumImageBytes: store.downloadPolicy.maximumPageBytes,
            cachePolicy: .disabled
        )
    }

    /// Recovery is local and conservative: incomplete attempts are paused and
    /// removed. Renamed files alone can never become a complete DB generation.
    public func prepare() async throws {
        do {
            if state?.activeJobID != nil, preparation == nil {
                throw LibraryDownloadServiceError.storageUnavailable
            }
            try await ensurePrepared()
            try await cleanupPending()
        } catch { throw LibraryDownloadServiceError.storageUnavailable }
    }

    /// Queuing and retrying validate a current source without starting network.
    @discardableResult
    public func enqueue(chapterID: Int64) async throws -> DownloadItem {
        try await prepare()
        let target = try await store.downloadTarget(chapterID: chapterID)
        let context = try await userContext(sourceID: target.manga.sourceId)
        try context.registration.checkAvailability()
        return try await store.enqueueDownload(chapterID: chapterID, expectedConfiguration: context.configuration)
    }

    @discardableResult
    public func retry(jobID: UUID) async throws -> DownloadItem {
        try await prepare()
        guard let item = try await store.downloadItem(jobID: jobID) else { throw DownloadPersistenceError.jobNotFound }
        let context = try await userContext(sourceID: item.manga.sourceId)
        try context.registration.checkAvailability()
        return try await store.retryDownload(jobID: jobID, expectedConfiguration: context.configuration)
    }

    /// Only this explicit action starts transfer. Stream ownership belongs to
    /// AppModel; disappearing views do not start or cancel a queue.
    public func start() async throws -> DownloadRun {
        guard state == nil else { throw LibraryDownloadServiceError.alreadyRunning }
        let id = UUID()
        let stream = AsyncStream<DownloadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state = State(id: id, continuation: stream.continuation)
        emit()
        state?.worker = Task { await self.run(id: id) }
        return DownloadRun(id: id, updates: stream.stream)
    }

    /// Pauses the active attempt and drains it; other queued rows remain queued
    /// until another explicit Start. The worker itself is never cancelled.
    public func pause() async throws {
        guard let current = state else { return }
        state?.stopRequested = true
        emit()
        if let jobID = current.activeJobID { _ = try await control(jobID: jobID, action: .pause) }
        await current.worker?.value
    }

    @discardableResult
    public func cancel(jobID: UUID) async throws -> DownloadItem? {
        try await control(jobID: jobID, action: .cancel)
    }

    /// Delete changes only the download job/files. Library membership, chapter
    /// progress and history are owned by the library and are left intact.
    @discardableResult
    public func delete(jobID: UUID) async throws -> DownloadItem? {
        try await control(jobID: jobID, action: .delete)
    }

    /// App awaits this before replacing/revoking a registry publication, even
    /// when its configuration is identical. Unrelated sources keep running.
    public func invalidateSources(sourceIDs: Set<Int64>) async throws {
        guard !sourceIDs.isEmpty else { return }
        for sourceID in sourceIDs { invalidatingSources[sourceID, default: 0] += 1 }
        defer {
            for sourceID in sourceIDs {
                let remaining = invalidatingSources[sourceID, default: 1] - 1
                invalidatingSources[sourceID] = remaining > 0 ? remaining : nil
            }
        }
        let task = Task {
            let cleanup = try await self.store.invalidateDownloadAttempts(sourceIDs: sourceIDs)
            if let current = self.state, let jobID = current.activeJobID,
               let sourceID = current.item?.manga.sourceId, sourceIDs.contains(sourceID) {
                _ = try await self.control(jobID: jobID, action: .invalidate(sourceIDs))
            }
            try await self.cleanup(cleanup)
        }
        do { try await task.value }
        catch { throw LibraryDownloadServiceError.storageUnavailable }
    }

    /// This route never asks for a source, admission or network capability.
    public func openOfflineChapter(chapterID: Int64) async throws -> OfflineChapterLease {
        try await prepare()
        guard let bundle = try await store.offlineChapter(chapterID: chapterID) else {
            throw LibraryDownloadServiceError.localChapterUnavailable
        }
        do {
            let lease = try await contentStore.open(identity: bundle.identity, manifestSHA256: bundle.manifestSHA256)
            guard lease.pages == bundle.pages else {
                await lease.close()
                throw LibraryDownloadServiceError.localChapterUnavailable
            }
            // Delete can occur while filesystem validation was suspended.
            let current = try await store.offlineChapter(chapterID: chapterID)
            guard current?.identity == bundle.identity,
                  current?.manifestSHA256 == bundle.manifestSHA256 else {
                await lease.close()
                throw LibraryDownloadServiceError.localChapterUnavailable
            }
            return lease
        } catch { throw LibraryDownloadServiceError.localChapterUnavailable }
    }

    private func ensurePrepared() async throws {
        if let preparation { return try await preparation.task.value }
        guard store.downloadPolicy == contentStore.policy else { throw LibraryDownloadServiceError.storageUnavailable }
        let id = UUID()
        let task = Task { [store, contentStore] in
            let recovered = try await store.recoverInterruptedDownloads()
            for identity in recovered.cleanup {
                if try await contentStore.remove(identity: identity) == .removed {
                    try await store.acknowledgeDownloadCleanup(identity: identity)
                }
            }
            let completed = try await store.completedDownloadIdentities()
            try await contentStore.reconcile(keeping: Set(completed.map(\.attemptID)))
        }
        preparation = Preparation(id: id, task: task)
        do { try await task.value }
        catch { if preparation?.id == id { preparation = nil }; throw error }
    }

    private func cleanupPending() async throws {
        for identity in try await store.pendingDownloadCleanup() {
            // A source lifecycle mutation may invalidate an active attempt.
            // Its files must remain until the corresponding operation drains.
            if state?.activeJobID == identity.jobID { continue }
            if try await contentStore.remove(identity: identity) == .removed {
                try await store.acknowledgeDownloadCleanup(identity: identity)
            }
        }
    }

    private func userContext(sourceID: Int64) async throws -> Context {
        guard invalidatingSources[sourceID] == nil else { throw LibraryDownloadServiceError.configurationUnavailable }
        do { return try context(await sourceProvider(sourceID), sourceID: sourceID) }
        catch let failure as Failure {
            throw failure.reason == .sourceUnavailable
                ? LibraryDownloadServiceError.sourceUnavailable
                : LibraryDownloadServiceError.configurationUnavailable
        }
    }

    private func context(_ value: DownloadSourceContext, sourceID: Int64) throws -> Context {
        switch value {
        case .unavailable: throw Failure(reason: .sourceUnavailable)
        case .configurationUnavailable: throw Failure(reason: .configurationChanged)
        case let .available(registration, configuration):
            guard registration.sourceID == sourceID else { throw Failure(reason: .configurationChanged) }
            switch registration.origin {
            case .native:
                guard sourceID == MangaDexSource().id, configuration == nil else {
                    throw Failure(reason: .configurationChanged)
                }
            case let .downloadedExtension(packageName):
                guard let configuration, configuration.installed.packageName == packageName,
                      configuration.installed.sourceIDs.contains(sourceID) else {
                    throw Failure(reason: .configurationChanged)
                }
            case .pinnedCompatibilityProfile:
                throw Failure(reason: .configurationChanged)
            }
            do { try registration.checkAvailability() }
            catch { throw Failure(reason: .configurationChanged) }
            return Context(registration: registration, configuration: configuration)
        }
    }

    private func run(id: UUID) async {
        do {
            try await ensurePrepared()
            while state?.id == id, state?.stopRequested == false {
                guard let item = try await store.nextQueuedDownload() else { break }
                guard state?.id == id, state?.stopRequested == false else { break }
                if let control = controls[item.jobID] { _ = try? await control.task.value; continue }
                state?.activeJobID = item.jobID
                state?.item = item
                emit()
                let operation = Task { await self.process(item, runID: id) }
                state?.operation = operation
                await operation.value
                if let control = controls[item.jobID] { _ = try? await control.task.value }
                guard state?.id == id else { return }
                state?.operation = nil
                state?.activeJobID = nil
                state?.attempt = nil
                state?.cancellingJobID = nil
                await pipeline.clear()
                try await cleanupPending()
                emit()
            }
        } catch {
            if state?.id == id { state?.error = .storageUnavailable }
        }
        guard let current = state, current.id == id else { return }
        await pipeline.clear()
        emit(phase: .finished)
        current.continuation.finish()
        state = nil
    }

    private func process(_ queued: DownloadItem, runID: UUID) async {
        var attempt: DownloadAttempt?
        do {
            let value = await sourceProvider(queued.manga.sourceId)
            try checkRun(runID, jobID: queued.jobID)
            let context = try context(value, sourceID: queued.manga.sourceId)
            let issued = try await persistence {
                try await self.store.beginDownloadAttempt(jobID: queued.jobID, expectedConfiguration: context.configuration)
            }
            attempt = issued
            state?.attempt = issued
            try check(runID, jobID: queued.jobID, registration: context.registration)
            try await content { try await self.contentStore.begin(identity: issued.identity) }
            let chapter = SChapterCompat(url: issued.chapter.url, name: issued.chapter.name,
                chapterNumber: Float(issued.chapter.number), scanlators: issued.chapter.scanlator.map { [$0] } ?? [],
                dateUpload: issued.chapter.dateUpload)
            let pages: [PageCompat]
            do { pages = try await context.registration.source.getPageList(chapter: chapter) }
            catch {
                try check(runID, jobID: queued.jobID, registration: context.registration)
                throw Failure(reason: .transferFailed)
            }
            try check(runID, jobID: queued.jobID, registration: context.registration)
            try Self.validate(pages, policy: issued.policy)
            state?.item = try await persistence { try await self.store.setDownloadPageCount(attempt: issued, pageCount: pages.count) }
            emit()
            for page in pages {
                try check(runID, jobID: queued.jobID, registration: context.registration)
                try await content { try await self.contentStore.reservePage(identity: issued.identity) }
                try check(runID, jobID: queued.jobID, registration: context.registration)
                let candidate = await context.registration.source.getImageRequest(page: page)
                try check(runID, jobID: queued.jobID, registration: context.registration)
                guard let candidate else { throw Failure(reason: .imageRequestUnavailable) }
                let request: ImageRequest
                do { request = try context.registration.scopedImageRequest(candidate) }
                catch { throw Failure(reason: .configurationChanged) }
                let data: Data
                do { data = try await pipeline.data(for: request) }
                catch {
                    try check(runID, jobID: queued.jobID, registration: context.registration)
                    throw Failure(reason: error is ReaderImagePipelineError ? .imageInvalid : .transferFailed)
                }
                try check(runID, jobID: queued.jobID, registration: context.registration)
                let receipt = try await content {
                    try await self.contentStore.writePage(identity: issued.identity, ordinal: page.index, data: data)
                }
                try check(runID, jobID: queued.jobID, registration: context.registration)
                state?.item = try await persistence { try await self.store.commitDownloadPage(attempt: issued, receipt: receipt) }
                emit()
            }
            try check(runID, jobID: queued.jobID, registration: context.registration)
            let manifest = try await content { try await self.contentStore.prepare(identity: issued.identity) }
            try check(runID, jobID: queued.jobID, registration: context.registration)
            state?.item = try await persistence { try await self.store.prepareDownload(attempt: issued, manifestReceipt: manifest) }
            try check(runID, jobID: queued.jobID, registration: context.registration)
            try await content { try await self.contentStore.publish(receipt: manifest) }
            try check(runID, jobID: queued.jobID, registration: context.registration)
            state?.item = try await persistence { try await self.store.completeDownload(attempt: issued, manifestReceipt: manifest) }
            emit()
        } catch is CancellationError {
            // Durable control invalidation happened before cancelling this
            // operation. Already committed complete generations are preserved.
            // A dependency may also cancel without a user control. In that
            // case a noncancelled task terminalizes the unfinished DB token.
            let abandoned = Task {
                await self.recordFailure(queued, attempt: attempt, runID: runID,
                    failure: Failure(reason: .interrupted))
            }
            await abandoned.value
        } catch {
            let failure: Failure
            if let typed = error as? Failure { failure = typed }
            else if let typed = error as? DownloadPersistenceError,
                    typed == .staleAttempt || typed == .invalidState {
                failure = Failure(reason: .configurationChanged)
            } else { failure = Failure(reason: .storageUnavailable, stopsQueue: true) }
            await recordFailure(queued, attempt: attempt, runID: runID, failure: failure)
        }
    }

    private func recordFailure(
        _ queued: DownloadItem, attempt: DownloadAttempt?, runID: UUID, failure: Failure
    ) async {
        guard state?.id == runID, controls[queued.jobID] == nil else { return }
        do {
            let mutation: DownloadMutation
            if let attempt { mutation = try await store.failDownload(attempt: attempt, reason: failure.reason) }
            else {
                mutation = try await store.failQueuedDownload(jobID: queued.jobID,
                    expectedRevision: queued.revision, reason: failure.reason)
            }
            state?.item = mutation.item
            try await cleanup(mutation.cleanup)
            state?.item = try await store.downloadItem(jobID: queued.jobID)
        } catch DownloadPersistenceError.staleAttempt {
            // Disable/cancel/retry owns the new durable generation.
            state?.item = try? await store.downloadItem(jobID: queued.jobID)
        } catch {
            state?.error = .storageUnavailable
            state?.stopRequested = true
            preparation = nil
        }
        if failure.stopsQueue { state?.error = .storageUnavailable; state?.stopRequested = true }
        emit()
    }

    /// Noncancelled control tasks first invalidate SQLite, then cancel/clear
    /// transfer, drain it, and finally acknowledge physical cleanup. A caller
    /// dropping its task cannot leave a cancelled generation executing later.
    private func control(jobID: UUID, action: Action) async throws -> DownloadItem? {
        if let existing = controls[jobID] {
            let item = try await existing.task.value
            if controls[jobID]?.id == existing.id { controls.removeValue(forKey: jobID) }
            if existing.action == action { return item }
            return try await control(jobID: jobID, action: action)
        }
        let id = UUID()
        let task = Task { try await self.applyControl(jobID: jobID, action: action) }
        controls[jobID] = Control(id: id, action: action, task: task)
        if state?.activeJobID == jobID { state?.cancellingJobID = jobID; emit() }
        do {
            let result = try await task.value
            if controls[jobID]?.id == id { controls.removeValue(forKey: jobID) }
            return result
        } catch {
            if controls[jobID]?.id == id { controls.removeValue(forKey: jobID) }
            throw LibraryDownloadServiceError.storageUnavailable
        }
    }

    private func applyControl(jobID: UUID, action: Action) async throws -> DownloadItem? {
        let mutation: DownloadMutation
        do {
            switch action {
            case .pause: mutation = try await store.pauseDownload(jobID: jobID)
            case .cancel: mutation = try await store.cancelDownload(jobID: jobID)
            case .delete: mutation = try await store.deleteDownload(jobID: jobID)
            case let .invalidate(sourceIDs):
                _ = try await store.invalidateDownloadAttempts(sourceIDs: sourceIDs)
                let cleanup = try await store.pendingDownloadCleanup().filter { sourceIDs.contains($0.sourceID) }
                mutation = DownloadMutation(item: try await store.downloadItem(jobID: jobID), cleanup: cleanup)
            }
        } catch {
            if state?.activeJobID == jobID {
                state?.error = .storageUnavailable
                state?.stopRequested = true
                state?.operation?.cancel()
                await pipeline.clear()
                await state?.operation?.value
                preparation = nil
            }
            throw error
        }
        if state?.activeJobID == jobID {
            let operation = state?.operation
            state?.operation?.cancel()
            await pipeline.clear()
            await operation?.value
        }
        do { try await cleanup(mutation.cleanup) }
        catch {
            state?.error = .storageUnavailable
            state?.stopRequested = true
            throw error
        }
        let item = try await store.downloadItem(jobID: jobID)
        if state?.activeJobID == jobID { state?.item = item; emit() }
        return item
    }

    private func cleanup(_ identities: [DownloadContentIdentity]) async throws {
        for identity in identities {
            if try await contentStore.remove(identity: identity) == .removed {
                try await store.acknowledgeDownloadCleanup(identity: identity)
            }
        }
    }

    private func checkRun(_ runID: UUID, jobID: UUID) throws {
        try Task.checkCancellation()
        guard state?.id == runID, state?.activeJobID == jobID,
              state?.stopRequested == false, controls[jobID] == nil else { throw CancellationError() }
        if let sourceID = state?.item?.manga.sourceId, invalidatingSources[sourceID] != nil {
            throw CancellationError()
        }
    }

    private func check(_ runID: UUID, jobID: UUID, registration: SourceRegistrationSnapshot) throws {
        try checkRun(runID, jobID: jobID)
        do { try registration.checkAvailability() }
        catch { throw Failure(reason: .configurationChanged) }
    }

    private func emit(phase: DownloadPhase? = nil) {
        guard let current = state else { return }
        current.continuation.yield(DownloadProgress(runID: current.id,
            phase: phase ?? (current.stopRequested || current.cancellingJobID != nil ? .cancelling : .running),
            activeJobID: current.activeJobID, cancellingJobID: current.cancellingJobID,
            item: current.item, error: current.error))
    }

    private static func validate(_ pages: [PageCompat], policy: DownloadPolicy) throws {
        guard !pages.isEmpty, pages.count <= policy.maximumPageCount else { throw Failure(reason: .pageListInvalid) }
        var metadataBytes = 0
        for (ordinal, page) in pages.enumerated() {
            guard page.index == ordinal, !page.url.isEmpty || !(page.imageURL ?? "").isEmpty else {
                throw Failure(reason: .pageListInvalid)
            }
            for value in [page.url, page.imageURL ?? ""] {
                guard value.utf8.count <= 4_096,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw Failure(reason: .pageListInvalid)
                }
                metadataBytes += value.utf8.count
                guard metadataBytes <= 8 * 1024 * 1024 else { throw Failure(reason: .pageListInvalid) }
            }
        }
    }

    private func persistence<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as DownloadPersistenceError {
            switch error {
            case .sourceIdentityMismatch: throw Failure(reason: .configurationChanged)
            case .mangaNotInLibrary: throw Failure(reason: .mangaRemoved)
            case .chapterNotFound, .chapterNotCurrent: throw Failure(reason: .chapterUnavailable)
            case .staleAttempt, .invalidState: throw error
            case .chapterLimitExceeded, .pageLimitExceeded: throw Failure(reason: .pageListInvalid)
            default: throw Failure(reason: .storageUnavailable, stopsQueue: true)
            }
        } catch { throw Failure(reason: .storageUnavailable, stopsQueue: true) }
    }

    private func content<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is DownloadImageValidationError { throw Failure(reason: .imageInvalid) }
        catch let error as DownloadContentError {
            switch error {
            case .quotaExceeded, .chapterTooLarge: throw Failure(reason: .quotaExceeded)
            case .storageFull: throw Failure(reason: .diskSpaceLow)
            case .imageTooLarge: throw Failure(reason: .imageInvalid)
            case .invalidManifest, .invalidPageOrder, .incompleteChapter: throw Failure(reason: .bundleCorrupt)
            case .attemptUnavailable, .pendingDeletion: throw Failure(reason: .configurationChanged)
            default: throw Failure(reason: .storageUnavailable, stopsQueue: true)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure(reason: .storageUnavailable, stopsQueue: true) }
    }
}

#endif
