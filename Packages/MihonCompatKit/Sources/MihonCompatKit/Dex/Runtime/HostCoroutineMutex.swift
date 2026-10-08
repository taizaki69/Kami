import Foundation

/// A bounded, non-reentrant Kotlin mutex. This owns no interpreter or DEX work:
/// its small synchronized state only retains opaque reference identities.
/// Waiting suspends the Swift task and checks VM cancellation at most every
/// 10 ms. FIFO handoff happens under the state lock, so new callers cannot
/// steal a permit from a suspended waiter.
final class HostCoroutineMutex: @unchecked Sendable {
    /// Retention prevents identity reuse. The referenced object's mutable
    /// contents are never inspected or passed across executors by this type.
    final class Owner: @unchecked Sendable {
        private let reference: AnyObject

        init(_ reference: AnyObject) { self.reference = reference }

        func matches(_ other: Owner) -> Bool { reference === other.reference }
    }

    enum Failure: Error, Equatable {
        case alreadyOwned, notLocked, wrongOwner, tooManyWaiters, timedOut
    }

    /// Tickets fence cancellation: cancelling an old waiter must never release
    /// a later acquisition, including a later acquisition with the same owner.
    final class Ticket: Sendable {
        fileprivate let owner: Owner?
        fileprivate init(owner: Owner?) { self.owner = owner }
    }

    private let stateLock = NSLock()
    private var holder: Ticket?
    private var waiters: [Ticket] = []
    private let maximumWaiters: Int

    init(locked: Bool, maximumWaiters: Int = 32) {
        self.maximumWaiters = max(1, min(maximumWaiters, 32))
        holder = locked ? Ticket(owner: nil) : nil
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    var isLocked: Bool { synchronized { holder != nil } }
    var waitingCount: Int { synchronized { waiters.count } }

    func holdsLock(owner: Owner) -> Bool {
        synchronized { holder?.owner?.matches(owner) == true }
    }

    func tryLock(owner: Owner?) throws -> Bool {
        try tryAcquire(owner: owner) != nil
    }

    func tryAcquire(owner: Owner?) throws -> Ticket? {
        try synchronized {
            try rejectReentry(owner)
            guard holder == nil else { return nil }
            let ticket = Ticket(owner: owner)
            holder = ticket
            return ticket
        }
    }

    func unlock(owner: Owner?) throws {
        try synchronized {
            guard let holder else { throw Failure.notLocked }
            if let owner, holder.owner?.matches(owner) != true { throw Failure.wrongOwner }
            handOff()
        }
    }

    /// Split acquisition also makes the cancellation-after-handoff boundary
    /// directly testable without timing-dependent task scheduling.
    func beginLock(owner: Owner?) throws -> (ticket: Ticket, immediate: Bool) {
        try synchronized {
            try rejectReentry(owner)
            let ticket = Ticket(owner: owner)
            if holder == nil {
                holder = ticket
                return (ticket, true)
            }
            guard waiters.count < maximumWaiters else { throw Failure.tooManyWaiters }
            waiters.append(ticket)
            return (ticket, false)
        }
    }

    func hasAcquired(_ ticket: Ticket) -> Bool { synchronized { holder === ticket } }

    func cancel(_ ticket: Ticket) {
        synchronized {
            if holder === ticket {
                handOff()
            } else {
                waiters.removeAll { $0 === ticket }
            }
        }
    }

    @discardableResult
    func lock(
        owner: Owner?,
        maximumWaitNanoseconds: UInt64,
        cancelled: () -> Bool
    ) async throws -> Ticket {
        let acquisition = try beginLock(owner: owner)
        // Kotlin's uncontended fast path does not itself check cancellation.
        // The interpreter independently checks its operation cancellation.
        guard !acquisition.immediate else { return acquisition.ticket }
        var delivered = false
        defer { if !delivered { cancel(acquisition.ticket) } }
        let wait = max(1, min(maximumWaitNanoseconds, 30_000_000_000))
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if Task.isCancelled || cancelled() { throw VMError.cancelled }
            if hasAcquired(acquisition.ticket) {
                // Include cancellation observed during handoff, before the
                // caller can enter its critical section.
                if Task.isCancelled || cancelled() { throw VMError.cancelled }
                delivered = true
                return acquisition.ticket
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard elapsed < wait else { throw Failure.timedOut }
            do {
                try await Task.sleep(nanoseconds: min(10_000_000, wait - elapsed))
            } catch is CancellationError {
                throw VMError.cancelled
            }
        }
    }

    // These helpers run only while stateLock is held.
    private func rejectReentry(_ owner: Owner?) throws {
        if let owner, holder?.owner?.matches(owner) == true { throw Failure.alreadyOwned }
    }

    private func handOff() {
        holder = waiters.isEmpty ? nil : waiters.removeFirst()
    }
}
