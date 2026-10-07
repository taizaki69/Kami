import Foundation

public enum LibraryRefreshRequestStatus: Equatable, Sendable {
    case disabled, scheduled(Date), systemUnavailable, submissionFailed, storageUnavailable
}

/// Platform-neutral scheduling and work ownership, injected with the one iOS
/// request identifier. No timers or network work are started by reconciliation.
@MainActor
public final class LibraryRefreshScheduler {
    public let settings: LibraryRefreshSettingsStore
    public private(set) var status = LibraryRefreshRequestStatus.disabled {
        didSet { onChange?() }
    }
    public private(set) var isRunning = false {
        didSet { onChange?() }
    }
    public var onChange: (() -> Void)?
    private let available: () -> Bool
    private let submit: (Date) throws -> Void
    private let cancelRequest: () -> Void
    private let now: () -> Date
    private var submitted: Date?
    private var worker: Task<Bool, Never>?

    public init(settings: LibraryRefreshSettingsStore, available: @escaping () -> Bool,
                submit: @escaping (Date) throws -> Void, cancelRequest: @escaping () -> Void,
                now: @escaping () -> Date = Date.init) {
        self.settings = settings; self.available = available; self.submit = submit
        self.cancelRequest = cancelRequest; self.now = now
    }

    public func save(enabled: Bool, interval: LibraryRefreshInterval, expectedRevision: UUID) throws {
        defer {
            if !settings.state.settings.enabled || settings.state.requiresRecovery { worker?.cancel() }
            reconcile()
        }
        try settings.save(enabled: enabled, interval: interval, expectedRevision: expectedRevision, now: now())
    }

    public func reconcile() {
        do { try settings.reconcile(now: now()) }
        catch {
            cancelRequest(); submitted = nil; worker?.cancel(); status = .storageUnavailable
            return
        }
        guard settings.state.settings.enabled, let next = settings.state.settings.nextEligibleAt else {
            cancelRequest(); submitted = nil; worker?.cancel(); status = .disabled
            return
        }
        guard available() else {
            cancelRequest(); submitted = nil; worker?.cancel(); status = .systemUnavailable
            return
        }
        // Preserve an already-submitted date: frequent scene changes must not
        // keep postponing a due request. A launch clears this local cache.
        if submitted == next, case .scheduled = status { return }
        do {
            try submit(next)
            submitted = next; status = .scheduled(next)
        } catch {
            cancelRequest(); submitted = nil; status = .submissionFailed
        }
    }

    /// Called only by the system launch handler. Saving Disabled cancels this
    /// worker; cancellation of its observer forwards to it and waits for drain.
    public func run(operation: @escaping @MainActor @Sendable () async -> LibraryRefreshOutcome) async -> Bool {
        guard worker == nil, !Task.isCancelled else { return false }
        submitted = nil
        do { try settings.reconcile(now: now()) }
        catch { reconcile(); return false }
        guard settings.state.settings.enabled, available() else { reconcile(); return false }
        guard let next = settings.state.settings.nextEligibleAt, now() >= next else { reconcile(); return true }
        let id: UUID
        do { id = try settings.beginAttempt(now: now()) }
        catch { reconcile(); return false }
        isRunning = true
        let task = Task { @MainActor in
            defer { self.worker = nil; self.isRunning = false; self.submitted = nil; self.reconcile() }
            let outcome: LibraryRefreshOutcome
            if Task.isCancelled { outcome = .cancelled }
            else { outcome = await operation() }
            // The bounded JSON validator respects Task cancellation. Finish
            // the durable outcome in a fresh owned cleanup task, then drain it
            // before reporting to iOS or allowing another automatic attempt.
            let stored = await Task { @MainActor in
                do { try self.settings.finishAttempt(id, outcome: outcome, now: self.now()); return true }
                catch { return false }
            }.value
            guard stored else { return false }
            return outcome == .completed
        }
        worker = task
        // Cache refers to the fired request; submit the next grant before work.
        reconcile()
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// OS expiration may arrive before work is installed, or from another queue.
/// Latch it and report completion exactly once, only after the worker drains.
public final class LibraryRefreshTaskOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var started = false
    private var completed = false
    private var worker: Task<Void, Never>?
    private let completion: @Sendable (Bool) -> Void

    public init(completion: @escaping @Sendable (Bool) -> Void) { self.completion = completion }

    public func start(_ operation: @escaping @Sendable () async -> Bool) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let task = Task {
            let mayStart = self.lock.withLock { !self.expired }
            let result = !mayStart || Task.isCancelled ? false : await operation()
            self.finish(result)
        }
        worker = task
        if expired { task.cancel() }
        lock.unlock()
    }

    public func expire() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        expired = true
        let task = worker
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ success: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let result = success && !expired
        worker = nil
        lock.unlock()
        completion(result)
    }
}
