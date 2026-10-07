import Foundation
import XCTest
@testable import KamiCore

final class LibraryRefreshTests: XCTestCase {
    @MainActor private final class Memory {
        enum Failure: Error { case io }
        enum Mode { case normal, beforeWrite, afterWrite, ignore }
        var data: Data?
        var unreadable = false
        var mode = Mode.normal
        var writes = 0
        var date = Date(timeIntervalSince1970: 1_000_000)
        var available = true
        var rejectRequest = false
        var requests: [Date] = []
        var cancellations = 0
        func store() -> LibraryRefreshSettingsStore {
            .init(read: {
                if self.unreadable { throw Failure.io }
                return self.data
            }, write: {
                self.writes += 1
                if self.mode == .beforeWrite { throw Failure.io }
                if self.mode != .ignore { self.data = $0 }
                if self.mode == .afterWrite { throw Failure.io }
            })
        }
        func scheduler(_ store: LibraryRefreshSettingsStore) -> LibraryRefreshScheduler {
            .init(settings: store, available: { self.available }, submit: {
                if self.rejectRequest { throw Failure.io }
                self.requests.append($0)
            }, cancelRequest: { self.cancellations += 1 }, now: { self.date })
        }
    }

    private actor Gate {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var open = false
        func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
        func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }

    @MainActor func testDefaultOffEnablePersistentDateAndNoLifecyclePostponement() async throws {
        let memory = Memory(), store = Memory().store()
        XCTAssertFalse(store.state.settings.enabled)
        let settings = memory.store(), scheduler = memory.scheduler(settings)
        scheduler.reconcile()
        XCTAssertTrue(memory.requests.isEmpty)
        try scheduler.save(enabled: true, interval: .sixHours, expectedRevision: settings.state.revision)
        let next = try XCTUnwrap(settings.state.settings.nextEligibleAt)
        XCTAssertEqual(next, memory.date.addingTimeInterval(900))
        memory.date.addTimeInterval(500)
        scheduler.reconcile(); scheduler.reconcile()
        XCTAssertEqual(memory.requests, [next])
        let reopened = memory.store()
        XCTAssertEqual(reopened.state.settings, settings.state.settings)
        let restored = memory.scheduler(reopened)
        restored.reconcile()
        XCTAssertEqual(memory.requests, [next, next])
        try scheduler.save(enabled: false, interval: .sixHours, expectedRevision: settings.state.revision)
        XCTAssertEqual(scheduler.status, .disabled)
        XCTAssertNil(settings.state.settings.nextEligibleAt)
        XCTAssertFalse(memory.store().state.settings.enabled)
    }

    @MainActor func testUnavailableSubmitFailureAndRetryNeverStartWork() async throws {
        let memory = Memory(), settings = Memory().store()
        let scheduler = memory.scheduler(settings)
        memory.available = false
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        XCTAssertEqual(scheduler.status, .systemUnavailable)
        XCTAssertTrue(memory.requests.isEmpty)
        memory.date.addTimeInterval(901)
        let unavailable = await scheduler.run { XCTFail("Unavailable scheduler must not call sources"); return .completed }
        XCTAssertFalse(unavailable)
        memory.available = true; memory.rejectRequest = true
        scheduler.reconcile()
        XCTAssertEqual(scheduler.status, .submissionFailed)
        XCTAssertTrue(settings.state.settings.enabled)
        memory.rejectRequest = false; scheduler.reconcile()
        XCTAssertEqual(memory.requests.count, 1)
        XCTAssertEqual(scheduler.status, .scheduled(try XCTUnwrap(settings.state.settings.nextEligibleAt)))
    }

    @MainActor func testDueRunSchedulesNextBeforeWorkAndRecordsPartialOutcome() async throws {
        let memory = Memory(), settings = Memory().store()
        let scheduler = memory.scheduler(settings)
        try scheduler.save(enabled: true, interval: .twelveHours, expectedRevision: settings.state.revision)
        let early = await scheduler.run { XCTFail("Too early"); return .completed }
        XCTAssertTrue(early)
        XCTAssertNil(settings.state.settings.lastAttempt)
        memory.date.addTimeInterval(900)
        let success = await scheduler.run {
            XCTAssertTrue(scheduler.isRunning)
            XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .running)
            XCTAssertEqual(memory.requests.last, memory.date.addingTimeInterval(43_200))
            return .partial
        }
        XCTAssertFalse(success)
        XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .partial)
        XCTAssertFalse(scheduler.isRunning)
        let repeated = await scheduler.run { XCTFail("No second request in the interval"); return .completed }
        XCTAssertTrue(repeated)
    }

    @MainActor func testDisableCancelsOnlyOwnedRunAndWaitsForItsDrain() async throws {
        let memory = Memory(), settings = Memory().store()
        let scheduler = memory.scheduler(settings), gate = Gate()
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        memory.date.addTimeInterval(900)
        let entered = expectation(description: "Owned operation started")
        let task = Task { await scheduler.run {
            entered.fulfill(); await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            return .cancelled
        } }
        await fulfillment(of: [entered], timeout: 3)
        let overlap = await scheduler.run { XCTFail("Overlapping launch"); return .completed }
        XCTAssertFalse(overlap)
        try scheduler.save(enabled: false, interval: .daily, expectedRevision: settings.state.revision)
        XCTAssertTrue(scheduler.isRunning, "Disabling must retain ownership until provider drain")
        XCTAssertEqual(scheduler.status, .disabled)
        await gate.release()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertFalse(settings.state.settings.enabled)
        XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .cancelled)
        let disabled = await scheduler.run { XCTFail("Disabled launch"); return .completed }
        XCTAssertFalse(disabled)
    }

    @MainActor func testObserverExpiryPropagatesAndBusyRetriesAfterFifteenMinutes() async throws {
        let memory = Memory(), settings = Memory().store()
        let scheduler = memory.scheduler(settings), gate = Gate()
        try scheduler.save(enabled: true, interval: .sixHours, expectedRevision: settings.state.revision)
        memory.date.addTimeInterval(900)
        let entered = expectation(description: "Expiry operation started")
        let task = Task { await scheduler.run {
            entered.fulfill(); await gate.wait()
            return Task.isCancelled ? .cancelled : .completed
        } }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel(); await gate.release()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .cancelled)
        memory.date.addTimeInterval(21_600)
        let busy = await scheduler.run { .busy }
        XCTAssertFalse(busy)
        XCTAssertEqual(settings.state.settings.nextEligibleAt, memory.date.addingTimeInterval(900))
        XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .busy)
    }

    @MainActor func testBackwardsClockClampsAndForwardJumpCreatesOnlyOneAttempt() async throws {
        let memory = Memory(), settings = memory.store(), scheduler = memory.scheduler(settings)
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        memory.date.addTimeInterval(-300_000); scheduler.reconcile()
        XCTAssertEqual(settings.state.settings.nextEligibleAt, memory.date.addingTimeInterval(86_400))
        memory.date.addTimeInterval(2_000_000)
        let completed = await scheduler.run { .completed }
        XCTAssertTrue(completed)
        XCTAssertEqual(settings.state.settings.nextEligibleAt, memory.date.addingTimeInterval(86_400))
        let revision = settings.state.revision
        _ = await scheduler.run { XCTFail("No catch-up burst"); return .completed }
        XCTAssertEqual(settings.state.revision, revision)
        try scheduler.save(enabled: true, interval: .sixHours, expectedRevision: revision)
        XCTAssertEqual(settings.state.settings.nextEligibleAt, memory.date.addingTimeInterval(21_600))
        XCTAssertEqual(memory.requests.last, settings.state.settings.nextEligibleAt)
    }

    @MainActor func testCorruptExternalABAAndStaleSettingsFailClosedUntilReviewedSave() async throws {
        let memory = Memory()
        memory.data = Data("corrupt".utf8)
        let settings = memory.store(), scheduler = memory.scheduler(settings)
        XCTAssertTrue(settings.state.requiresRecovery)
        scheduler.reconcile()
        XCTAssertEqual(scheduler.status, .storageUnavailable)
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        let oldRevision = settings.state.revision, saved = memory.data
        try scheduler.save(enabled: false, interval: .daily, expectedRevision: oldRevision)
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        XCTAssertThrowsError(try scheduler.save(enabled: false, interval: .daily, expectedRevision: oldRevision))
        memory.data = Data("external bytes".utf8)
        scheduler.reconcile()
        XCTAssertFalse(settings.state.settings.enabled)
        XCTAssertTrue(settings.state.requiresRecovery)
        memory.data = saved
        scheduler.reconcile()
        XCTAssertTrue(settings.state.requiresRecovery, "An external ABA must not silently re-enable checks")
        try scheduler.save(enabled: false, interval: .daily, expectedRevision: settings.state.revision)
        XCTAssertFalse(settings.state.requiresRecovery)
        XCTAssertFalse(memory.store().state.settings.enabled)
    }

    @MainActor func testWriteFailuresAndUnreadableStorageDoNotStartAnAttempt() async throws {
        for mode in [Memory.Mode.beforeWrite, .afterWrite, .ignore] {
            let memory = Memory(), settings = memory.store(), scheduler = memory.scheduler(settings)
            try scheduler.save(enabled: true, interval: .sixHours, expectedRevision: settings.state.revision)
            memory.date.addTimeInterval(900); memory.mode = mode
            let result = await scheduler.run { XCTFail("Unconfirmed attempt write must not reach provider"); return .completed }
            XCTAssertFalse(result)
            XCTAssertTrue(settings.state.requiresRecovery)
            XCTAssertEqual(scheduler.status, .storageUnavailable)
            memory.mode = .normal
            try scheduler.save(enabled: false, interval: .daily, expectedRevision: settings.state.revision)
            XCTAssertFalse(memory.store().state.settings.enabled)
        }
        let memory = Memory(); memory.unreadable = true
        let settings = memory.store(), scheduler = memory.scheduler(settings)
        scheduler.reconcile()
        XCTAssertTrue(settings.state.requiresRecovery)
        XCTAssertTrue(memory.requests.isEmpty)
        XCTAssertThrowsError(try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision))
    }

    @MainActor func testFinishWriteFailureKeepsDurableChapterWorkButStopsAutomaticChecks() async throws {
        let memory = Memory(), settings = memory.store(), scheduler = memory.scheduler(settings)
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        memory.date.addTimeInterval(900)
        var committed = false
        let result = await scheduler.run { committed = true; memory.mode = .beforeWrite; return .completed }
        XCTAssertTrue(committed)
        XCTAssertFalse(result)
        XCTAssertEqual(scheduler.status, .storageUnavailable)
        let reopened = memory.store()
        XCTAssertEqual(reopened.state.settings.lastAttempt?.outcome, .running)
        XCTAssertGreaterThan(try XCTUnwrap(reopened.state.settings.nextEligibleAt), memory.date,
                             "An interrupted attempt cannot immediately repeat after reopening")
    }

    @MainActor func testDisablingThenReenablingDuringDrainKeepsNewChoicesAndSystemRestrictionCancels() async throws {
        let memory = Memory(), settings = memory.store(), scheduler = memory.scheduler(settings)
        try scheduler.save(enabled: true, interval: .daily, expectedRevision: settings.state.revision)
        memory.date.addTimeInterval(900)
        let gate = Gate(), entered = expectation(description: "Draining across changed preferences")
        let task = Task { await scheduler.run {
            entered.fulfill(); await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            return .cancelled
        } }
        await fulfillment(of: [entered], timeout: 3)
        memory.available = false; scheduler.reconcile()
        XCTAssertEqual(scheduler.status, .systemUnavailable)
        try scheduler.save(enabled: false, interval: .daily, expectedRevision: settings.state.revision)
        try scheduler.save(enabled: true, interval: .sixHours, expectedRevision: settings.state.revision)
        let next = settings.state.settings.nextEligibleAt
        await gate.release(); _ = await task.value
        XCTAssertTrue(settings.state.settings.enabled)
        XCTAssertEqual(settings.state.settings.interval, .sixHours)
        XCTAssertEqual(settings.state.settings.nextEligibleAt, next)
        XCTAssertEqual(settings.state.settings.lastAttempt?.outcome, .cancelled)
        memory.available = true; scheduler.reconcile()
        XCTAssertEqual(scheduler.status, .scheduled(try XCTUnwrap(next)))
    }

    @MainActor func testAtomicFileReopensAndInvalidDocumentsNeverEnableWork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("refresh.json")
        let settings = LibraryRefreshSettingsStore(fileURL: file)
        XCTAssertFalse(settings.state.settings.enabled)
        let now = Date(timeIntervalSince1970: 2_000_000)
        try settings.save(enabled: true, interval: .sixHours, expectedRevision: settings.state.revision, now: now)
        XCTAssertEqual(LibraryRefreshSettingsStore(fileURL: file).state.settings, settings.state.settings)
        let valid = try Data(contentsOf: file)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for (key, value) in [("version", 2 as Any), ("enabled", 1), ("interval", 1), ("extra", 0)] {
            var broken = json; broken[key] = value
            XCTAssertThrowsError(try LibraryRefreshSettingsStore.decode(JSONSerialization.data(withJSONObject: broken)))
        }
        json["nextEligibleAt"] = NSNull()
        XCTAssertThrowsError(try LibraryRefreshSettingsStore.decode(JSONSerialization.data(withJSONObject: json)))
        let repeated = "{\"version\":1,\"enabled\":false,\"enabled\":true,\"interval\":24}"
        for data in [Data(repeated.utf8), Data(repeating: 32, count: 4_097), Data("[]".utf8), Data("{}".utf8)] {
            XCTAssertThrowsError(try LibraryRefreshSettingsStore.decode(data))
            try data.write(to: file)
            let reopened = LibraryRefreshSettingsStore(fileURL: file)
            XCTAssertTrue(reopened.state.requiresRecovery)
            XCTAssertFalse(reopened.state.settings.enabled)
        }
        let freshMemory = Memory(), fresh = freshMemory.store()
        for time in [Double.nan, .infinity, -1, 999_999_999_999] {
            XCTAssertThrowsError(try fresh.reconcile(now: Date(timeIntervalSince1970: time))) {
                XCTAssertEqual($0 as? LibraryRefreshSettingsError, .invalidDocument)
            }
        }
    }

    func testOSOwnerExpiresBeforeInstallAndCompletesOnlyOnce() async {
        let done = expectation(description: "Expired before start")
        done.assertForOverFulfill = true
        let owner = LibraryRefreshTaskOwner { result in XCTAssertFalse(result); done.fulfill() }
        owner.expire()
        owner.start { XCTFail("Expired work must not start"); return true }
        owner.start { XCTFail("Duplicate start"); return true }
        await fulfillment(of: [done], timeout: 3)
        owner.expire()
    }

    func testOSOwnerReportsSuccessAndIgnoresExpirationAfterCompletion() async {
        let done = expectation(description: "Successful completion")
        done.assertForOverFulfill = true
        let owner = LibraryRefreshTaskOwner { success in XCTAssertTrue(success); done.fulfill() }
        owner.start { true }
        await fulfillment(of: [done], timeout: 3)
        owner.expire()
        owner.start { XCTFail("Completed owner cannot restart"); return false }
    }

    func testOSOwnerWaitsForNonCooperativeWorkerAndRejectsLateSuccess() async {
        let entered = expectation(description: "Owner worker started"), done = expectation(description: "Drained completion")
        done.assertForOverFulfill = true
        let gate = Gate()
        final class Probe: @unchecked Sendable {
            let lock = NSLock(); var released = false
            func release() { lock.withLock { released = true } }
            var isReleased: Bool { lock.withLock { released } }
        }
        let probe = Probe()
        let owner = LibraryRefreshTaskOwner { success in
            XCTAssertTrue(probe.isReleased, "Expiry must not report completion while work still owns storage")
            XCTAssertFalse(success)
            done.fulfill()
        }
        owner.start { entered.fulfill(); await gate.wait(); return true }
        await fulfillment(of: [entered], timeout: 3)
        owner.expire(); owner.expire()
        probe.release(); await gate.release()
        await fulfillment(of: [done], timeout: 3)
        owner.expire()
    }
}
