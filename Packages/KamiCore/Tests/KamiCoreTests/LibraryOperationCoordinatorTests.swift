import Foundation
import XCTest
@testable import KamiCore

@MainActor
final class LibraryOperationCoordinatorTests: XCTestCase {
    @MainActor private final class Gate {
        private var entered = false
        private var opened = false
        private var entrances: [CheckedContinuation<Void, Never>] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            let pending = entrances; entrances = []
            pending.forEach { $0.resume() }
            if !opened { await withCheckedContinuation { waiters.append($0) } }
        }
        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { entrances.append($0) } }
        }
        func release() {
            opened = true
            let pending = waiters; waiters = []
            pending.forEach { $0.resume() }
        }
    }

    private struct Failure: Error {}

    private func expect<T>(
        _ expected: LibraryOperationError, _ action: () throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do { _ = try action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? LibraryOperationError, expected, file: file, line: line) }
    }

    func testIntentIsReservedBeforeItsTaskStarts() async throws {
        let coordinator = LibraryOperationCoordinator()
        let generation = coordinator.state.presentation
        var entered = false
        let worker = try coordinator.start(expected: generation) {
            entered = true
            try coordinator.validateCurrentOperation()
            return 17
        }
        XCTAssertFalse(entered)
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        expect(.operationsInProgress) { try coordinator.beginExclusive(expected: generation) }
        let value = try await worker.value
        XCTAssertEqual(value, 17)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testClosingAndCancellingDoNotReleaseASuspendedWorker() async throws {
        let coordinator = LibraryOperationCoordinator()
        let generation = coordinator.state.presentation
        let lease = try coordinator.open(expected: generation)
        let gate = Gate()
        let worker = try lease.start {
            await gate.wait()
            try coordinator.validateCurrentOperation()
            try Task.checkCancellation()
        }
        await gate.waitUntilEntered()
        lease.close()
        lease.close()
        worker.cancel()
        expect(.invalidOperation) { try lease.start {} }
        expect(.operationsInProgress) { try coordinator.beginExclusive(expected: generation) }
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        gate.release()
        do { try await worker.value; XCTFail("Expected worker cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testObserverCancellationDoesNotCancelTheOwnedWork() async throws {
        let coordinator = LibraryOperationCoordinator()
        let gate = Gate()
        let worker = try coordinator.start(expected: coordinator.state.presentation) {
            await gate.wait()
            try Task.checkCancellation()
            return 29
        }
        let observer = Task { try await worker.value }
        await gate.waitUntilEntered()
        observer.cancel()
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        gate.release()
        let value = try await observer.value
        XCTAssertEqual(value, 29)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testQueuedCancellationRunsNoBodyAndReleasesItsReservation() async throws {
        let coordinator = LibraryOperationCoordinator()
        var effect = false
        let worker = try coordinator.start(expected: coordinator.state.presentation) { effect = true }
        worker.cancel()
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        do { try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(effect)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testThrowingWorkerReleasesAndNeverLeavesAnAmbientScope() async throws {
        let coordinator = LibraryOperationCoordinator()
        let worker = try coordinator.start(expected: coordinator.state.presentation) {
            try coordinator.validateCurrentOperation()
            throw Failure()
        }
        do { _ = try await worker.value; XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(coordinator.state.activeOperations, 0)
        expect(.invalidOperation) { try coordinator.validateCurrentOperation() }
    }

    func testIndependentChildKeepsOwnershipAfterParentReturns() async throws {
        let coordinator = LibraryOperationCoordinator()
        let generation = coordinator.state.presentation
        let gate = Gate()
        let parent = try coordinator.start(expected: generation) {
            try coordinator.start(expected: generation) {
                await gate.wait()
                try coordinator.validateCurrentOperation()
            }
        }
        let child = try await parent.value
        await gate.waitUntilEntered()
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        expect(.operationsInProgress) { try coordinator.beginExclusive(expected: generation) }
        gate.release()
        try await child.value
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testTwoScenesShareOneExclusionBoundaryAndDoubleCloseCannotReleaseTheOther() async throws {
        let shared = LibraryOperationCoordinator()
        let generation = shared.state.presentation
        let first = try shared.open(expected: generation)
        let second = try shared.open(expected: generation)
        first.close()
        first.close()
        XCTAssertEqual(shared.state.activeOperations, 1)
        expect(.operationsInProgress) { try shared.beginExclusive(expected: generation) }
        second.close()
        let exclusive = try shared.beginExclusive(expected: generation)
        expect(.exclusiveInProgress) { try shared.open(expected: generation) }
        try shared.finishExclusive(exclusive)
    }

    func testForeignAndConsumedExclusiveTokensNeverUnlockAnotherOwner() async throws {
        let first = LibraryOperationCoordinator(), second = LibraryOperationCoordinator()
        let a = try first.beginExclusive(expected: first.state.presentation)
        let b = try second.beginExclusive(expected: second.state.presentation)
        expect(.invalidOperation) { try second.finishExclusive(a) }
        expect(.invalidOperation) { try second.publishCommittedChange(a) }
        XCTAssertTrue(second.state.isExclusive)
        try first.finishExclusive(a)
        expect(.invalidOperation) { try first.finishExclusive(a) }
        try second.finishExclusive(b)
        expect(.stalePresentation) { try first.open(expected: second.state.presentation) }
    }

    func testAbortKeepsPresentationAndCommitPublishesOnceWhileStillExclusive() async throws {
        let coordinator = LibraryOperationCoordinator()
        let old = coordinator.state.presentation
        let abandoned = try coordinator.beginExclusive(expected: old)
        try coordinator.finishExclusive(abandoned)
        XCTAssertEqual(coordinator.state.presentation, old)

        var states: [LibraryOperationState] = []
        coordinator.onStateChanged = { states.append($0) }
        let committed = try coordinator.beginExclusive(expected: old)
        try coordinator.publishCommittedChange(committed)
        let current = coordinator.state.presentation
        XCTAssertNotEqual(current, old)
        XCTAssertTrue(coordinator.state.isExclusive)
        expect(.stalePresentation) { try coordinator.open(expected: old) }
        expect(.exclusiveInProgress) { try coordinator.open(expected: current) }
        expect(.invalidOperation) { try coordinator.publishCommittedChange(committed) }
        try coordinator.finishExclusive(committed)
        XCTAssertEqual(states.map(\.isExclusive), [false, true, true, false])
        XCTAssertEqual(states.map(\.presentation), [old, old, current, current])
        let fresh = try coordinator.open(expected: current)
        fresh.close()
    }

    func testCancellationAfterPublicationDoesNotRevertTheCommittedGeneration() async throws {
        let coordinator = LibraryOperationCoordinator()
        let exclusive = try coordinator.beginExclusive(expected: coordinator.state.presentation)
        try coordinator.publishCommittedChange(exclusive)
        let committed = coordinator.state.presentation
        let gate = Gate()
        let cleanup = Task {
            await gate.wait()
            try coordinator.finishExclusive(exclusive)
        }
        await gate.waitUntilEntered()
        cleanup.cancel()
        gate.release()
        try await cleanup.value
        XCTAssertEqual(coordinator.state.presentation, committed)
        XCTAssertFalse(coordinator.state.isExclusive)
    }

    func testDeferredLifecycleCannotAdoptANewerPresentation() async throws {
        let coordinator = LibraryOperationCoordinator()
        let captured = coordinator.state.presentation
        let gate = Gate()
        var effect = false
        let lifecycle = Task {
            await gate.wait()
            return try coordinator.start(expected: captured) { effect = true }
        }
        await gate.waitUntilEntered()
        let exclusive = try coordinator.beginExclusive(expected: captured)
        try coordinator.publishCommittedChange(exclusive)
        try coordinator.finishExclusive(exclusive)
        gate.release()
        do { _ = try await lifecycle.value; XCTFail("Old lifecycle was rebased") }
        catch { XCTAssertEqual(error as? LibraryOperationError, .stalePresentation) }
        XCTAssertFalse(effect)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testPromptLifetimeRemainsOwnedBetweenPreparationAndConfirmation() async throws {
        let coordinator = LibraryOperationCoordinator(maximumOperations: 1)
        let lease = try coordinator.open(expected: coordinator.state.presentation)
        let prepared = try lease.start { 7 }
        _ = try await prepared.value
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        expect(.operationLimitReached) { try coordinator.open(expected: coordinator.state.presentation) }
        let gate = Gate()
        // Cleanup/control work borrows its existing lease even at the global limit.
        let confirmation = try lease.start { await gate.wait() }
        lease.close()
        await gate.waitUntilEntered()
        expect(.operationsInProgress) { try coordinator.beginExclusive(expected: coordinator.state.presentation) }
        gate.release()
        try await confirmation.value
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testWorkerLimitRejectsWithoutLosingAlreadyRegisteredWorkers() async throws {
        let coordinator = LibraryOperationCoordinator()
        let lease = try coordinator.open(expected: coordinator.state.presentation)
        let gate = Gate()
        let workers = try (0..<LibraryOperationLease.maximumWorkers).map { _ in
            try lease.start { await gate.wait() }
        }
        expect(.operationLimitReached) { try lease.start {} }
        lease.close()
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        gate.release()
        for worker in workers { try await worker.value }
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testScopeChecksOwnerAndRemainsValidUntilBorrowedWorkDrains() async throws {
        let coordinator = LibraryOperationCoordinator(), other = LibraryOperationCoordinator()
        let lease = try coordinator.open(expected: coordinator.state.presentation)
        let gate = Gate()
        let worker = Task {
            try await lease.withScope {
                self.expect(.invalidOperation) { try other.validateCurrentOperation() }
                await gate.wait()
                try coordinator.validateCurrentOperation()
            }
        }
        await gate.waitUntilEntered()
        lease.close()
        XCTAssertEqual(coordinator.state.activeOperations, 1)
        gate.release()
        try await worker.value
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testInheritedScopeCannotAuthorizeWorkAfterItsOwnerFinishes() async throws {
        let coordinator = LibraryOperationCoordinator()
        let gate = Gate()
        let parent = try coordinator.start(expected: coordinator.state.presentation) {
            Task {
                await gate.wait()
                try coordinator.validateCurrentOperation()
            }
        }
        let unowned = try await parent.value
        await gate.waitUntilEntered()
        XCTAssertEqual(coordinator.state.activeOperations, 0)
        gate.release()
        do { try await unowned.value; XCTFail("Inherited scope renewed ownership") }
        catch { XCTAssertEqual(error as? LibraryOperationError, .invalidOperation) }
    }
}
