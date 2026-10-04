import Foundation
import XCTest
@testable import KamiCore

#if canImport(SQLite3)

@MainActor
final class ReadingStateWriterTests: XCTestCase {
    @MainActor private final class Gate {
        private var entered = false
        private var open = false
        private var entrance: [CheckedContinuation<Void, Never>] = []
        private var blocked: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            let waiting = entrance
            entrance.removeAll()
            for continuation in waiting { continuation.resume() }
            guard !open else { return }
            await withCheckedContinuation { blocked.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entrance.append($0) }
        }

        func release() {
            open = true
            let waiting = blocked
            blocked.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    private struct Fixture {
        let store: LibraryStore
        let targets: [ChapterWriteTarget]
    }
    private struct SecretFailure: Error, LocalizedError {
        var errorDescription: String? { "SQL failure at /private/database https://secret.invalid/token" }
    }

    private func fixture(_ count: Int = 3) async throws -> Fixture {
        let store = try LibraryStore(inMemory: true)
        let id = try await store.upsert(Manga(sourceId: 7, url: "/writer", title: "Synthetic queue fixture"))
        try await store.replaceChapters(mangaId: id, with: (0..<count).map {
            Chapter(mangaId: id, sourceOrder: $0, url: "/chapter/\($0)", name: "Chapter \($0)")
        })
        let result = try await store.readingSnapshot(sourceID: 7, mangaURL: "/writer")
        let snapshot = try XCTUnwrap(result)
        let targets = try snapshot.currentChapters.map { chapter in
            try XCTUnwrap(snapshot.target(for: try XCTUnwrap(chapter.id)))
        }
        return Fixture(store: store, targets: targets)
    }

    private static func persist(
        _ fixture: Fixture, _ target: ChapterWriteTarget, _ intent: ReadingStateWriteIntent
    ) async throws -> Chapter {
        switch intent {
        case let .progress(page, reachedEnd, lastRead):
            return try await fixture.store.commitReadingProgress(
                target: target, page: page, reachedEnd: reachedEnd, lastRead: lastRead).chapter
        case let .read(read):
            return try await fixture.store.setChapterRead(read, target: target)
        }
    }

    private func expectError(
        _ receipt: ReadingStateWriteReceipt, _ expected: ReadingStateWriterError
    ) async {
        do {
            _ = try await receipt.value()
            XCTFail("Expected a finite queue error")
        } catch {
            XCTAssertEqual(error as? ReadingStateWriterError, expected)
        }
    }

    func testSharedBarrierOwnsQueuedReadingUntilCancelledObserverAndWorkerDrain() async throws {
        let f = try await fixture(1)
        let coordinator = LibraryOperationCoordinator()
        let presentation = coordinator.state.presentation
        let gate = Gate()
        let writer = ReadingStateWriter(persisting: { target, intent in
            await gate.wait()
            return try await Self.persist(f, target, intent)
        }, operationCoordinator: coordinator)
        let receipt = writer.enqueueProgress(target: f.targets[0], page: 7, reachedEnd: true, lastRead: 99)
        XCTAssertEqual(coordinator.state.activeOperations, 1, "The intent is owned before its worker starts")
        let observer = Task { try? await receipt.value() }
        await gate.waitUntilEntered()
        observer.cancel()
        do { _ = try coordinator.beginExclusive(expected: presentation); XCTFail("Reading is still pending") }
        catch { XCTAssertEqual(error as? LibraryOperationError, .operationsInProgress) }
        gate.release()
        await writer.captureFrontier().wait()
        _ = await observer.value
        let saved = try await f.store.validateReadingTarget(f.targets[0])
        XCTAssertEqual(saved.lastPageRead, 7)
        XCTAssertTrue(saved.read)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
        let exclusive = try coordinator.beginExclusive(expected: presentation)
        try coordinator.finishExclusive(exclusive)
    }

    func testExclusiveBarrierRetainsRejectedReadingForRetryAfterAbort() async throws {
        let f = try await fixture(1)
        let coordinator = LibraryOperationCoordinator()
        let writer = ReadingStateWriter(store: f.store, operationCoordinator: coordinator)
        let generation = coordinator.state.presentation
        let exclusive = try coordinator.beginExclusive(expected: generation)
        let receipt = writer.enqueueRead(true, target: f.targets[0])
        do { _ = try await receipt.value(); XCTFail("Exclusive work must reject the save") }
        catch { XCTAssertEqual(error as? LibraryOperationError, .exclusiveInProgress) }
        XCTAssertEqual(coordinator.state.activeOperations, 0)
        let before = try await f.store.validateReadingTarget(f.targets[0])
        XCTAssertFalse(before.read)
        let failure = try XCTUnwrap(writer.failures.first)
        XCTAssertTrue(failure.canRetry)
        try coordinator.finishExclusive(exclusive)
        let retried = try await writer.retry(failure).value()
        XCTAssertTrue(retried.read)
        XCTAssertTrue(writer.failures.isEmpty)
        XCTAssertEqual(coordinator.state.presentation, generation)
        XCTAssertEqual(coordinator.state.activeOperations, 0)
    }

    func testCloseAndNextCancelOnlyObserverAndDrainBothCapturedEvents() async throws {
        let f = try await fixture()
        let gate = Gate()
        let writer = ReadingStateWriter(persisting: { target, intent in
            if target == f.targets[0] { await gate.wait() }
            XCTAssertFalse(Task.isCancelled)
            return try await Self.persist(f, target, intent)
        })
        let first = writer.enqueueProgress(target: f.targets[0], page: 3, reachedEnd: true, lastRead: 100)
        let observer = Task { try await first.value() }
        await gate.waitUntilEntered()
        observer.cancel()
        do {
            _ = try await observer.value
            XCTFail("The cancelled observer should stop before the blocked save finishes")
        } catch { XCTAssertTrue(error is CancellationError) }
        // Equivalent to immediately opening a neighbour after closing the old view.
        let next = writer.enqueueProgress(target: f.targets[1], page: 1, reachedEnd: false, lastRead: 101)
        let frontier = writer.captureFrontier()
        gate.release()
        await frontier.wait()
        let oldChapter = try await f.store.validateReadingTarget(f.targets[0])
        let nextChapter = try await next.value()
        let history = try await f.store.history()
        XCTAssertTrue(oldChapter.read)
        XCTAssertEqual(oldChapter.lastPageRead, 3)
        XCTAssertEqual(nextChapter.lastPageRead, 1)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(writer.failures.isEmpty)
    }

    func testDroppingWriterAndReceiptObserverDoesNotDiscardOwnedWorker() async throws {
        let f = try await fixture()
        let gate = Gate()
        var writer: ReadingStateWriter? = ReadingStateWriter(persisting: { target, intent in
            await gate.wait()
            return try await Self.persist(f, target, intent)
        })
        weak var retained = writer
        let receipt = try XCTUnwrap(writer).enqueueProgress(
            target: f.targets[0], page: 0, reachedEnd: true, lastRead: 100)
        await gate.waitUntilEntered()
        writer = nil
        XCTAssertNotNil(retained)
        gate.release()
        let saved = try await receipt.value()
        XCTAssertTrue(saved.read)
        let stored = try await f.store.validateReadingTarget(f.targets[0])
        XCTAssertTrue(stored.read)
    }

    func testPendingEndThenBackwardsScrollingSharesReceiptAndPreservesEndEvidence() async throws {
        let f = try await fixture()
        let gate = Gate()
        var calls: [ChapterWriteTarget] = []
        let writer = ReadingStateWriter(persisting: { target, intent in
            calls.append(target)
            if target == f.targets[1] { await gate.wait() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueRead(false, target: f.targets[1])
        await gate.waitUntilEntered()
        let end = writer.enqueueProgress(target: f.targets[0], page: 9, reachedEnd: true, lastRead: 100)
        let backwards = writer.enqueueProgress(target: f.targets[0], page: 4, reachedEnd: false, lastRead: 101)
        XCTAssertTrue(end === backwards)
        for page in 0..<1_000 {
            let coalesced = writer.enqueueProgress(
                target: f.targets[0], page: Int64(page), reachedEnd: false, lastRead: 102)
            XCTAssertTrue(coalesced === end)
        }
        gate.release()
        let saved = try await backwards.value()
        let history = try await f.store.history()
        XCTAssertEqual(saved.lastPageRead, 999)
        XCTAssertTrue(saved.read)
        XCTAssertEqual(history.first?.2, 102)
        XCTAssertEqual(calls, [f.targets[1], f.targets[0]])
    }

    func testInFlightFailedEndEvidenceTransfersToNewerBackwardsProgress() async throws {
        let f = try await fixture()
        let gate = Gate()
        var first = true
        let writer = ReadingStateWriter(persisting: { target, intent in
            if first {
                first = false
                await gate.wait()
                throw SecretFailure()
            }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueProgress(target: f.targets[0], page: 9, reachedEnd: true, lastRead: 100)
        await gate.waitUntilEntered()
        let backwards = writer.enqueueProgress(target: f.targets[0], page: 2, reachedEnd: false, lastRead: 101)
        gate.release()
        let saved = try await backwards.value()
        XCTAssertEqual(saved.lastPageRead, 2)
        XCTAssertTrue(saved.read)
        XCTAssertTrue(writer.failures.isEmpty)
    }

    func testManualUnreadFollowsFinalEventAndBreaksEndInheritance() async throws {
        let f = try await fixture()
        let gate = Gate()
        var calls: [ReadingStateWriteIntent] = []
        let writer = ReadingStateWriter(persisting: { target, intent in
            calls.append(intent)
            if calls.count == 1 { await gate.wait() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueProgress(target: f.targets[0], page: 9, reachedEnd: true, lastRead: 100)
        await gate.waitUntilEntered()
        let unread = writer.enqueueRead(false, target: f.targets[0])
        let backwards = writer.enqueueProgress(target: f.targets[0], page: 1, reachedEnd: false, lastRead: 101)
        gate.release()
        let manual = try await unread.value()
        let saved = try await backwards.value()
        XCTAssertFalse(manual.read)
        XCTAssertFalse(saved.read)
        XCTAssertEqual(calls, [.progress(page: 9, reachedEnd: true, lastRead: 100),
                               .read(false), .progress(page: 1, reachedEnd: false, lastRead: 101)])
    }

    func testRetainsFiniteOriginalFailureAndRetriesItsExactIntent() async throws {
        let f = try await fixture()
        var fail = true
        var updates: [[ReadingStateWriteFailure]] = []
        let writer = ReadingStateWriter(persisting: { target, intent in
            if fail { throw SecretFailure() }
            return try await Self.persist(f, target, intent)
        })
        writer.onFailuresChanged = { updates.append($0) }
        _ = writer.enqueueProgress(target: f.targets[0], page: 7, reachedEnd: true, lastRead: 123)
        await writer.captureFrontier().wait()
        let failure = try XCTUnwrap(writer.failures.first)
        XCTAssertEqual(failure.target, f.targets[0])
        XCTAssertEqual(failure.intent, .progress(page: 7, reachedEnd: true, lastRead: 123))
        XCTAssertFalse(failure.message.contains("SQL"))
        XCTAssertFalse(failure.message.contains("secret.invalid"))
        XCTAssertTrue(failure.canRetry)
        fail = false
        let saved = try await writer.retry(failure).value()
        XCTAssertEqual(saved.lastPageRead, 7)
        XCTAssertTrue(saved.read)
        XCTAssertTrue(writer.failures.isEmpty)
        XCTAssertTrue(updates.contains { $0.first?.id == failure.id })
        XCTAssertEqual(updates.last, [])
    }

    func testPendingOrSuccessfulNewerProgressRejectsObsoleteRetryWithoutRewinding() async throws {
        let f = try await fixture()
        let gate = Gate()
        var fail = true
        let writer = ReadingStateWriter(persisting: { target, intent in
            if fail { throw SecretFailure() }
            await gate.wait()
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueProgress(target: f.targets[0], page: 7, reachedEnd: false, lastRead: 100)
        await writer.captureFrontier().wait()
        let failure = try XCTUnwrap(writer.failures.first)
        fail = false
        let newer = writer.enqueueProgress(target: f.targets[0], page: 8, reachedEnd: false, lastRead: 101)
        await gate.waitUntilEntered()
        XCTAssertFalse(try XCTUnwrap(writer.failures.first).canRetry)
        await expectError(writer.retry(failure), .obsoleteFailure)
        gate.release()
        let saved = try await newer.value()
        XCTAssertEqual(saved.lastPageRead, 8)
        XCTAssertTrue(writer.failures.isEmpty)
        await expectError(writer.retry(failure), .obsoleteFailure)
    }

    func testSuccessForOtherTargetDoesNotClearFailureAndDismissRevokesRetry() async throws {
        let f = try await fixture()
        let writer = ReadingStateWriter(persisting: { target, intent in
            if target == f.targets[0] { throw SecretFailure() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueRead(false, target: f.targets[0])
        let other = writer.enqueueRead(true, target: f.targets[1])
        _ = try await other.value()
        let failure = try XCTUnwrap(writer.failures.first)
        XCTAssertTrue(failure.canRetry)
        XCTAssertEqual(failure.target, f.targets[0])
        writer.dismissFailure(id: failure.id)
        XCTAssertTrue(writer.failures.isEmpty)
        await expectError(writer.retry(failure), .obsoleteFailure)
    }

    func testStaleAndInvalidTargetsNeverOfferRetry() async throws {
        let f = try await fixture(6)
        let errors: [ReadingStateError] = [
            .staleEpoch, .foreignTarget, .identityChanged, .mangaNotFound, .chapterNotFound, .invalidInput,
        ]
        let writer = ReadingStateWriter(persisting: { target, _ in
            throw errors[try XCTUnwrap(f.targets.firstIndex(of: target))]
        })
        for target in f.targets { _ = writer.enqueueRead(false, target: target) }
        await writer.captureFrontier().wait()
        XCTAssertEqual(writer.failures.count, errors.count)
        for failure in writer.failures {
            XCTAssertFalse(failure.canRetry)
            await expectError(writer.retry(failure), .obsoleteFailure)
        }
    }

    func testFailedManualUnreadRemainsVisibleAfterOrdinaryProgressSuccess() async throws {
        let f = try await fixture()
        _ = try await f.store.setChapterRead(true, target: f.targets[0])
        let writer = ReadingStateWriter(persisting: { target, intent in
            if case .read = intent { throw SecretFailure() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueRead(false, target: f.targets[0])
        await writer.captureFrontier().wait()
        let original = try XCTUnwrap(writer.failures.first)
        let progress = writer.enqueueProgress(target: f.targets[0], page: 2, reachedEnd: false, lastRead: 100)
        let saved = try await progress.value()
        let retained = try XCTUnwrap(writer.failures.first)
        XCTAssertTrue(saved.read)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.intent, .read(false))
        XCTAssertFalse(retained.canRetry)
        XCTAssertTrue(retained.message.contains("superseded"))
        await expectError(writer.retry(original), .obsoleteFailure)
    }

    func testManualSuccessDoesNotHideFailedPageHistoryOrReviveOldEndLatch() async throws {
        let f = try await fixture()
        var failProgress = true
        let writer = ReadingStateWriter(persisting: { target, intent in
            if case .progress = intent, failProgress { throw SecretFailure() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueProgress(target: f.targets[0], page: 9, reachedEnd: true, lastRead: 100)
        await writer.captureFrontier().wait()
        let failure = try XCTUnwrap(writer.failures.first)
        _ = try await writer.enqueueRead(false, target: f.targets[0]).value()
        XCTAssertEqual(writer.failures.first?.id, failure.id)
        XCTAssertFalse(try XCTUnwrap(writer.failures.first).canRetry)
        let historyBefore = try await f.store.history()
        XCTAssertTrue(historyBefore.isEmpty)
        failProgress = false
        let saved = try await writer.enqueueProgress(
            target: f.targets[0], page: 1, reachedEnd: false, lastRead: 101).value()
        XCTAssertFalse(saved.read)
        XCTAssertEqual(saved.lastPageRead, 1)
        XCTAssertTrue(writer.failures.isEmpty)
    }

    func testDifferentFailedFieldFamiliesRemainVisible() async throws {
        let f = try await fixture()
        let writer = ReadingStateWriter(persisting: { _, _ in throw SecretFailure() })
        _ = writer.enqueueProgress(target: f.targets[0], page: 4, reachedEnd: true, lastRead: 100)
        _ = writer.enqueueRead(false, target: f.targets[0])
        await writer.captureFrontier().wait()
        XCTAssertEqual(writer.failures.count, 2)
        XCTAssertEqual(writer.failures.map(\.intent), [
            .progress(page: 4, reachedEnd: true, lastRead: 100), .read(false),
        ])
        XCTAssertFalse(writer.failures[0].canRetry)
        XCTAssertTrue(writer.failures[1].canRetry)
    }

    func testOverflowManualBarrierWinsOverOlderActiveEndAndOlderSuccess() async throws {
        let f = try await fixture()
        let gate = Gate()
        let writer = ReadingStateWriter(persisting: { target, intent in
            if target == f.targets[0] { await gate.wait() }
            return try await Self.persist(f, target, intent)
        }, maximumPendingIntents: 1)
        _ = writer.enqueueProgress(target: f.targets[0], page: 9, reachedEnd: true, lastRead: 100)
        await gate.waitUntilEntered()
        _ = writer.enqueueRead(false, target: f.targets[1])
        let unread = writer.enqueueRead(false, target: f.targets[0])
        await expectError(unread, .pendingLimitExceeded)
        let backwards = writer.enqueueProgress(target: f.targets[0], page: 2, reachedEnd: false, lastRead: 101)
        await expectError(backwards, .pendingLimitExceeded)
        XCTAssertEqual(writer.failures.last?.intent, .progress(page: 2, reachedEnd: false, lastRead: 101))
        let frontier = writer.captureFrontier()
        gate.release()
        await frontier.wait()
        XCTAssertEqual(writer.failures.count, 2)
        XCTAssertEqual(writer.failures.first?.intent, .read(false))
        XCTAssertEqual(writer.failures.last?.intent, .progress(page: 2, reachedEnd: false, lastRead: 101))
    }

    func testFrontierSealsPendingTailAndDoesNotWaitForNewerBlockedWrite() async throws {
        let f = try await fixture()
        let firstGate = Gate(), laterGate = Gate()
        let writer = ReadingStateWriter(persisting: { target, intent in
            if target == f.targets[0] { await firstGate.wait() }
            if case .progress(page: 2, reachedEnd: _, lastRead: _) = intent { await laterGate.wait() }
            return try await Self.persist(f, target, intent)
        })
        _ = writer.enqueueRead(false, target: f.targets[0])
        await firstGate.waitUntilEntered()
        let first = writer.enqueueProgress(target: f.targets[1], page: 1, reachedEnd: false, lastRead: 100)
        let frontier = writer.captureFrontier()
        let later = writer.enqueueProgress(target: f.targets[1], page: 2, reachedEnd: false, lastRead: 101)
        XCTAssertFalse(first === later)
        firstGate.release()
        await laterGate.waitUntilEntered()
        await frontier.wait()
        let savedAtFrontier = try await f.store.validateReadingTarget(f.targets[1])
        XCTAssertEqual(savedAtFrontier.lastPageRead, 1)
        laterGate.release()
        let savedLater = try await later.value()
        XCTAssertEqual(savedLater.lastPageRead, 2)
    }

    func testPendingAndFailureCapsStayFiniteAndOverflowMessageIsExplicit() async throws {
        let f = try await fixture(5)
        let gate = Gate()
        let writer = ReadingStateWriter(persisting: { target, _ in
            if target == f.targets[0] { await gate.wait() }
            throw SecretFailure()
        }, maximumPendingIntents: 1, maximumFailures: 2)
        _ = writer.enqueueRead(false, target: f.targets[0])
        await gate.waitUntilEntered()
        _ = writer.enqueueRead(false, target: f.targets[1])
        for target in f.targets.dropFirst(2) {
            await expectError(writer.enqueueRead(false, target: target), .pendingLimitExceeded)
        }
        XCTAssertEqual(writer.failures.count, 2)
        XCTAssertEqual(writer.discardedFailureCount, 1)
        XCTAssertTrue(writer.failures[0].message.contains("Earlier failures"))
        let frontier = writer.captureFrontier()
        gate.release()
        await frontier.wait()
        XCTAssertEqual(writer.failures.count, 2)
        XCTAssertEqual(writer.discardedFailureCount, 3)
    }

    func testEvictedFailureNoticeSurvivesLastRetainedRetryUntilExplicitAcknowledgment() async throws {
        let f = try await fixture()
        var fail = true
        let writer = ReadingStateWriter(persisting: { target, intent in
            if fail { throw SecretFailure() }
            return try await Self.persist(f, target, intent)
        }, maximumFailures: 1)
        var notifications: [Int] = []
        writer.onFailuresChanged = { [weak writer] _ in
            notifications.append(writer?.discardedFailureCount ?? -1)
        }
        _ = writer.enqueueRead(false, target: f.targets[0])
        _ = writer.enqueueRead(false, target: f.targets[1])
        await writer.captureFrontier().wait()
        XCTAssertEqual(writer.discardedFailureCount, 1)
        let retained = try XCTUnwrap(writer.failures.first)
        XCTAssertEqual(retained.target, f.targets[1])
        fail = false
        _ = try await writer.retry(retained).value()
        XCTAssertTrue(writer.failures.isEmpty)
        XCTAssertEqual(writer.discardedFailureCount, 1)
        XCTAssertEqual(notifications.last, 1)
        let beforeAcknowledgment = notifications.count
        writer.acknowledgeDiscardedFailures()
        XCTAssertEqual(writer.discardedFailureCount, 0)
        XCTAssertEqual(notifications.count, beforeAcknowledgment + 1)
        XCTAssertEqual(notifications.last, 0)
    }
}

#endif
