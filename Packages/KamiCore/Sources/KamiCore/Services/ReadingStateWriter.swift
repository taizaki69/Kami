import Foundation

#if canImport(SQLite3)

public enum ReadingStateWriteIntent: Equatable, Sendable {
    case progress(page: Int64, reachedEnd: Bool, lastRead: Int64)
    case read(Bool)
}

public enum ReadingStateWriterError: Error, Equatable, Sendable, LocalizedError {
    case pendingLimitExceeded
    case obsoleteFailure
    case sequenceLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .pendingLimitExceeded:
            return "Too many reading saves are waiting. Retry after the pending saves finish."
        case .obsoleteFailure:
            return "A newer reading action superseded this failed save."
        case .sequenceLimitExceeded:
            return "The reading save queue is unavailable. Reopen the app."
        }
    }
}

/// A retained failure describes the original guarded intent, never SQL or URLs.
public struct ReadingStateWriteFailure: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let target: ChapterWriteTarget
    public let intent: ReadingStateWriteIntent
    public let message: String
    public let canRetry: Bool
}

/// Observing or cancelling a receipt never owns/cancels its persistence worker.
/// Coalesced pending events share a receipt and receive the latest saved chapter.
@MainActor
public final class ReadingStateWriteReceipt {
    fileprivate let id = UUID()
    private var result: Result<Chapter, Error>?
    private var observers: [UUID: CheckedContinuation<Chapter, Error>] = [:]

    fileprivate init() {}

    public func value() async throws -> Chapter {
        let observerID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result {
                    continuation.resume(with: result)
                } else {
                    observers[observerID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelObserver(observerID) }
        }
    }

    fileprivate func resolve(_ result: Result<Chapter, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiting = observers.values
        observers.removeAll()
        for observer in waiting { observer.resume(with: result) }
    }

    private func cancelObserver(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// Capturing a frontier seals its pending tail. Later scrolling cannot extend
/// the prefix being awaited. Failures remain in the writer's independent state.
@MainActor
public struct ReadingStateWriteFrontier {
    private let receipt: ReadingStateWriteReceipt?
    fileprivate init(receipt: ReadingStateWriteReceipt?) { self.receipt = receipt }

    public func wait() async {
        guard let receipt else { return }
        _ = try? await receipt.value()
    }
}

/// App-owned FIFO for reading writes. It owns a worker through completion even
/// when the originating view/receipt observer disappears. Targets still need
/// Core validation: this queue neither grants authority nor coordinates restore.
@MainActor
public final class ReadingStateWriter {
    public nonisolated static let maximumPendingIntents = 128
    public nonisolated static let maximumFailures = 16

    typealias Persistence = @MainActor (ChapterWriteTarget, ReadingStateWriteIntent) async throws -> Chapter

    private struct Pending {
        let target: ChapterWriteTarget
        var intent: ReadingStateWriteIntent
        var sequence: UInt64
        let receipt: ReadingStateWriteReceipt
        var sealed = false
    }
    private struct Failure {
        let id: UUID
        let target: ChapterWriteTarget
        let intent: ReadingStateWriteIntent
        let sequence: UInt64
        let message: String
        let retryPermitted: Bool
        var superseded = false
    }
    private struct Success {
        let target: ChapterWriteTarget
        let intent: ReadingStateWriteIntent
        let sequence: UInt64
    }

    private let persist: Persistence
    private let pendingLimit: Int
    private let failureLimit: Int
    private let operationCoordinator: LibraryOperationCoordinator
    private var pending: [Pending] = []
    private var active: Pending?
    private var worker: Task<Void, Error>?
    private var startingWorker = false
    private var sequence: UInt64 = 0
    private var retainedFailures: [Failure] = []
    // Only targets with retained failures need a later successful-intent barrier.
    private var successBarriers: [Success] = []
    private var publishedFailures: [ReadingStateWriteFailure] = []
    private var publishedDiscardedFailureCount = 0

    /// Overflow retains the newest bounded failure set. The count is saturating;
    /// the first retained message also reports omissions until dismissed.
    public private(set) var discardedFailureCount = 0

    public var onFailuresChanged: (([ReadingStateWriteFailure]) -> Void)? {
        didSet { onFailuresChanged?(failures) }
    }

    public var failures: [ReadingStateWriteFailure] {
        retainedFailures.enumerated().map { index, failure in
            let omitted = index == 0 && discardedFailureCount > 0
                ? " Earlier failures could not all be retained; review recently read chapters."
                : ""
            let superseded = failure.superseded || hasNewerRetainedIntent(
                target: failure.target, sequence: failure.sequence)
            let notice = superseded
                ? " A newer action superseded this save. Reopen the chapter to save its current state."
                : ""
            return ReadingStateWriteFailure(
                id: failure.id, target: failure.target, intent: failure.intent,
                message: failure.message + notice + omitted,
                canRetry: failure.retryPermitted && !superseded
                    && !hasNewerOutstanding(target: failure.target, sequence: failure.sequence))
        }
    }

    public convenience init(store: LibraryStore, operationCoordinator: LibraryOperationCoordinator? = nil) {
        self.init(persisting: { target, intent in
            switch intent {
            case let .progress(page, reachedEnd, lastRead):
                return try await store.commitReadingProgress(
                    target: target, page: page, reachedEnd: reachedEnd, lastRead: lastRead).chapter
            case let .read(read):
                return try await store.setChapterRead(read, target: target)
            }
        }, operationCoordinator: operationCoordinator)
    }

    /// Deterministic test seam; production uses the guarded LibraryStore APIs.
    init(
        persisting: @escaping Persistence,
        maximumPendingIntents: Int = ReadingStateWriter.maximumPendingIntents,
        maximumFailures: Int = ReadingStateWriter.maximumFailures,
        operationCoordinator: LibraryOperationCoordinator? = nil
    ) {
        precondition((1...Self.maximumPendingIntents).contains(maximumPendingIntents))
        precondition((1...Self.maximumFailures).contains(maximumFailures))
        self.persist = persisting
        self.pendingLimit = maximumPendingIntents
        self.failureLimit = maximumFailures
        self.operationCoordinator = operationCoordinator ?? LibraryOperationCoordinator()
    }

    public func enqueueProgress(
        target: ChapterWriteTarget, page: Int64, reachedEnd: Bool, lastRead: Int64
    ) -> ReadingStateWriteReceipt {
        let end = reachedEnd || inheritedReachedEnd(for: target)
        return enqueue(target: target, intent: .progress(page: page, reachedEnd: end, lastRead: lastRead))
    }

    public func enqueueRead(_ read: Bool, target: ChapterWriteTarget) -> ReadingStateWriteReceipt {
        enqueue(target: target, intent: .read(read))
    }

    public func captureFrontier() -> ReadingStateWriteFrontier {
        if let index = pending.indices.last {
            pending[index].sealed = true
            return ReadingStateWriteFrontier(receipt: pending[index].receipt)
        }
        return ReadingStateWriteFrontier(receipt: active?.receipt)
    }

    public func retry(_ failure: ReadingStateWriteFailure) -> ReadingStateWriteReceipt {
        guard let current = retainedFailures.first(where: { $0.id == failure.id }),
              current.target == failure.target, current.intent == failure.intent,
              current.retryPermitted, !current.superseded,
              !hasNewerRetainedIntent(target: current.target, sequence: current.sequence),
              !hasNewerOutstanding(target: current.target, sequence: current.sequence) else {
            return rejectedReceipt(ReadingStateWriterError.obsoleteFailure)
        }
        return enqueue(target: current.target, intent: current.intent)
    }

    public func dismissFailure(id: UUID) {
        retainedFailures.removeAll { $0.id == id }
        pruneSuccessBarriers()
        publishFailures()
    }

    public func acknowledgeDiscardedFailures() {
        discardedFailureCount = 0
        publishFailures()
    }

    private func enqueue(target: ChapterWriteTarget, intent: ReadingStateWriteIntent) -> ReadingStateWriteReceipt {
        guard sequence < UInt64.max else {
            return rejectedReceipt(ReadingStateWriterError.sequenceLimitExceeded)
        }
        sequence += 1
        let currentSequence = sequence
        if let index = pending.indices.last, !pending[index].sealed,
           pending[index].target == target,
           case let .progress(_, previousEnd, _) = pending[index].intent,
           case let .progress(page, reachedEnd, lastRead) = intent {
            pending[index].intent = .progress(page: page, reachedEnd: previousEnd || reachedEnd, lastRead: lastRead)
            pending[index].sequence = currentSequence
            publishFailures()
            return pending[index].receipt
        }

        let receipt = ReadingStateWriteReceipt()
        let item = Pending(target: target, intent: intent, sequence: currentSequence, receipt: receipt)
        guard pending.count < pendingLimit else {
            let error = ReadingStateWriterError.pendingLimitExceeded
            recordFailure(item, error: error)
            receipt.resolve(.failure(error))
            publishFailures()
            return receipt
        }
        pending.append(item)
        if worker == nil, !startingWorker {
            // Unstructured and never exposed: observer cancellation cannot
            // cancel this worker or discard the last reading event.
            startingWorker = true
            do {
                worker = try operationCoordinator.start(expected: operationCoordinator.state.presentation) { [self] in
                    await run()
                }
            } catch {
                pending.removeAll { $0.receipt === receipt }
                let finite = finiteError(error)
                recordFailure(item, error: finite)
                receipt.resolve(.failure(finite))
            }
            startingWorker = false
        }
        publishFailures()
        return receipt
    }

    private func run() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            active = item
            let result: Result<Chapter, Error>
            do {
                let chapter = try await persist(item.target, item.intent)
                succeeded(item)
                result = .success(chapter)
            } catch {
                let finite = finiteError(error)
                recordFailure(item, error: finite)
                result = .failure(finite)
            }
            active = nil
            item.receipt.resolve(result)
            publishFailures()
        }
        worker = nil
    }

    private func inheritedReachedEnd(for target: ChapterWriteTarget) -> Bool {
        // A later manual read/unread forms a barrier and must not inherit an
        // earlier end event. Progress following an in-flight failed end event
        // retains that evidence, even before the failure has been delivered.
        var latest: (sequence: UInt64, intent: ReadingStateWriteIntent)?
        func consider(_ sequence: UInt64, _ intent: ReadingStateWriteIntent) {
            if latest == nil || sequence > latest!.sequence { latest = (sequence, intent) }
        }
        for item in pending where item.target == target { consider(item.sequence, item.intent) }
        if let active, active.target == target { consider(active.sequence, active.intent) }
        for failure in retainedFailures where failure.target == target { consider(failure.sequence, failure.intent) }
        for success in successBarriers where success.target == target { consider(success.sequence, success.intent) }
        if let latest, case let .progress(_, reachedEnd, _) = latest.intent { return reachedEnd }
        return false
    }

    private func hasNewerOutstanding(target: ChapterWriteTarget, sequence: UInt64) -> Bool {
        (active.map { $0.target == target && $0.sequence > sequence } ?? false)
            || pending.contains { $0.target == target && $0.sequence > sequence }
    }

    private func hasNewerRetainedIntent(target: ChapterWriteTarget, sequence: UInt64) -> Bool {
        retainedFailures.contains { $0.target == target && $0.sequence > sequence }
            || successBarriers.contains { $0.target == target && $0.sequence > sequence }
    }

    private func sameFamily(_ lhs: ReadingStateWriteIntent, _ rhs: ReadingStateWriteIntent) -> Bool {
        switch (lhs, rhs) {
        case (.progress, .progress), (.read, .read): return true
        default: return false
        }
    }

    private func succeeded(_ item: Pending) {
        retainedFailures.removeAll {
            $0.target == item.target && $0.sequence <= item.sequence && sameFamily($0.intent, item.intent)
        }
        for index in retainedFailures.indices where retainedFailures[index].target == item.target
            && retainedFailures[index].sequence < item.sequence {
            retainedFailures[index].superseded = true
        }
        successBarriers.removeAll { $0.target == item.target }
        if retainedFailures.contains(where: { $0.target == item.target }) {
            successBarriers.append(Success(target: item.target, intent: item.intent, sequence: item.sequence))
        }
        pruneSuccessBarriers()
    }

    private func pruneSuccessBarriers() {
        successBarriers.removeAll { success in
            !retainedFailures.contains(where: { $0.target == success.target })
        }
    }

    private func retryPermitted(_ error: Error) -> Bool {
        guard let error = error as? ReadingStateError else { return true }
        switch error {
        case .foreignTarget, .staleEpoch, .identityChanged, .mangaNotFound, .chapterNotFound, .invalidInput:
            return false
        default:
            return true
        }
    }

    private func recordFailure(_ item: Pending, error: Error) {
        if let previous = retainedFailures.first(where: {
            $0.target == item.target && sameFamily($0.intent, item.intent)
        }),
           previous.sequence > item.sequence { return }
        retainedFailures.removeAll { $0.target == item.target && sameFamily($0.intent, item.intent) }
        retainedFailures.append(Failure(id: item.receipt.id, target: item.target,
                                        intent: item.intent, sequence: item.sequence,
                                        message: error.localizedDescription, retryPermitted: retryPermitted(error)))
        retainedFailures.sort { $0.sequence < $1.sequence }
        if retainedFailures.count > failureLimit {
            retainedFailures.removeFirst()
            if discardedFailureCount < Int.max { discardedFailureCount += 1 }
        }
        pruneSuccessBarriers()
    }

    private func finiteError(_ error: Error) -> Error {
        if let error = error as? ReadingStateError { return error }
        if let error = error as? ReadingStateWriterError { return error }
        if let error = error as? LibraryOperationError { return error }
        return ReadingStateError.storageUnavailable
    }

    private func rejectedReceipt(_ error: Error) -> ReadingStateWriteReceipt {
        let receipt = ReadingStateWriteReceipt()
        receipt.resolve(.failure(error))
        return receipt
    }

    private func publishFailures() {
        let current = failures
        guard current != publishedFailures || discardedFailureCount != publishedDiscardedFailureCount else { return }
        publishedFailures = current
        publishedDiscardedFailureCount = discardedFailureCount
        onFailuresChanged?(current)
    }
}

#endif
