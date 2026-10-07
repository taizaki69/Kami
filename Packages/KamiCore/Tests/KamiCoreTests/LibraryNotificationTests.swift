import Foundation
import XCTest
@testable import KamiCore

final class LibraryNotificationTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
        func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    private actor Ledger: LibraryNotificationPersisting {
        var enabled = true
        var revision: Int64 = 1
        var pending: LibraryNotificationBatch? = .init(id: UUID(), chapterCount: 3, incomplete: true)
        var batch: LibraryNotificationBatch?
        var outcome: LibraryNotificationOutcome?
        var readsFail = false, savesFail = false, finishesFail = false
        var claims = 0
        func enqueueNewBatch() { pending = .init(id: UUID(), chapterCount: 1, incomplete: false) }
        func failures(read: Bool = false, save: Bool = false, finish: Bool = false) {
            readsFail = read; savesFail = save; finishesFail = finish
        }
        func seed(enabled: Bool = true, outcome: LibraryNotificationOutcome? = nil) {
            self.enabled = enabled
            self.outcome = outcome
            if outcome != nil { batch = pending; pending = nil }
        }
        func libraryNotificationSettings() throws -> LibraryNotificationSettings {
            if readsFail { throw LibraryNotificationError.storageUnavailable }
            return .init(enabled: enabled, revision: revision, batch: batch, outcome: outcome)
        }
        func saveLibraryNotificationSettings(enabled: Bool, expectedRevision: Int64) throws -> LibraryNotificationSettings {
            if savesFail { throw LibraryNotificationError.storageUnavailable }
            guard expectedRevision == revision else { throw LibraryNotificationError.settingsChanged }
            revision += 1; self.enabled = enabled
            if !enabled { batch = nil; outcome = nil }
            return try libraryNotificationSettings()
        }
        func claimLibraryNotificationBatch(expectedRevision: Int64) throws -> LibraryNotificationBatch? {
            guard enabled, expectedRevision == revision else { throw LibraryNotificationError.settingsChanged }
            claims += 1
            guard let pending else { return nil }
            self.pending = nil; batch = pending; outcome = .attempting
            return pending
        }
        func finishLibraryNotificationBatch(id: UUID, outcome: LibraryNotificationOutcome) throws {
            if finishesFail { throw LibraryNotificationError.storageUnavailable }
            if batch?.id == id, self.outcome == .attempting { self.outcome = outcome }
        }
    }
    @MainActor private final class Platform: LibraryNotificationPlatform {
        var permission = LibraryNotificationAuthorization.allowed
        var permissionRequests = 0
        var submitted: [LibraryNotificationBatch] = []
        var removed: [String] = []
        var delivered = Set<String>()
        var onSubmit: ((LibraryNotificationBatch) async throws -> Void)?
        var onAuthorization: (() async -> Void)?
        func authorization() async -> LibraryNotificationAuthorization { await onAuthorization?(); return permission }
        func requestAuthorization() async throws { permissionRequests += 1; permission = .allowed }
        func contains(identifier: String) async -> Bool { delivered.contains(identifier) }
        func submit(_ batch: LibraryNotificationBatch) async throws {
            submitted.append(batch)
            try await onSubmit?(batch)
            delivered.insert(batch.identifier)
        }
        func remove(identifier: String) async { removed.append(identifier); delivered.remove(identifier) }
        func removeOwned() async {
            for identifier in delivered.filter(LibraryNotificationBatch.owns) { await remove(identifier: identifier) }
        }
    }

    @MainActor func testDefaultOffDeniedAndPermissionAreSeparateFromProcessing() async throws {
        let ledger = Ledger(), platform = Platform()
        await ledger.seed(enabled: false)
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        await service.process()
        XCTAssertEqual(service.settings?.enabled, false)
        XCTAssertTrue(platform.submitted.isEmpty)
        platform.permission = .notDetermined
        try await service.save(enabled: true, expectedRevision: 1)
        await service.process()
        XCTAssertEqual(platform.permissionRequests, 0)
        XCTAssertTrue(platform.submitted.isEmpty)
        platform.permission = .denied
        await service.process(); await service.requestPermission()
        XCTAssertEqual(platform.permissionRequests, 0)
        XCTAssertTrue(platform.submitted.isEmpty)
        platform.permission = .notDetermined
        await service.requestPermission()
        XCTAssertEqual(platform.permissionRequests, 1)
        await service.process(); await service.process()
        XCTAssertEqual(platform.submitted.count, 1)
        XCTAssertEqual(service.settings?.outcome, .submitted)
    }

    @MainActor func testDurableClaimPrecedesOSAndReopenDoesNotRepeatOrReplayDismissedAlert() async throws {
        let ledger = Ledger(), platform = Platform()
        platform.onSubmit = { batch in
            let saved = try await ledger.libraryNotificationSettings()
            XCTAssertEqual(saved.batch, batch)
            XCTAssertEqual(saved.outcome, .attempting)
        }
        await LibraryNotificationService(persistence: ledger, platform: platform).process()
        await LibraryNotificationService(persistence: ledger, platform: platform).process()
        platform.delivered = []
        await LibraryNotificationService(persistence: ledger, platform: platform).process()
        XCTAssertEqual(platform.submitted.count, 1)
    }

    @MainActor func testInterruptedAttemptReconcilesPresenceButNeverBlindlyResendsAbsence() async throws {
        for present in [false, true] {
            let ledger = Ledger(), platform = Platform()
            await ledger.seed(outcome: .attempting)
            let before = try await ledger.libraryNotificationSettings()
            if present { platform.delivered.insert(try XCTUnwrap(before.batch).identifier) }
            let reopened = LibraryNotificationService(persistence: ledger, platform: platform)
            await reopened.process()
            XCTAssertTrue(platform.submitted.isEmpty)
            XCTAssertEqual(reopened.settings?.outcome, present ? .submitted : .unconfirmed)
        }
    }

    @MainActor func testDisableAndReenableDuringNoncooperativeSubmissionRemovesOnlyOldAlert() async throws {
        let ledger = Ledger(), platform = Platform(), gate = Gate(), entered = Gate()
        platform.delivered.insert("another-feature")
        platform.onSubmit = { _ in await entered.release(); await gate.wait() }
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        let work = Task { await service.process() }
        await entered.wait()
        await service.process() // same owner cannot submit a second copy
        try await service.save(enabled: false, expectedRevision: 1)
        try await service.save(enabled: true, expectedRevision: 2)
        await gate.release(); await work.value
        XCTAssertEqual(platform.submitted.count, 1)
        XCTAssertEqual(platform.delivered, ["another-feature"])
        XCTAssertEqual(service.settings?.enabled, true)
        XCTAssertEqual(service.settings?.revision, 3)
    }

    @MainActor func testCancellationDrainsLateSuccessAndPersistsUnconfirmedWithoutRetry() async throws {
        let ledger = Ledger(), platform = Platform(), gate = Gate(), entered = Gate()
        platform.onSubmit = { _ in await entered.release(); await gate.wait() }
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        var finished = false
        let work = Task { await service.process(); finished = true }
        await entered.wait(); work.cancel()
        XCTAssertFalse(finished)
        await gate.release(); await work.value
        XCTAssertTrue(platform.delivered.isEmpty)
        XCTAssertEqual(service.settings?.outcome, .unconfirmed)
        await service.process()
        XCTAssertEqual(platform.submitted.count, 1)
    }

    @MainActor func testPermissionPreflightRevokedByDisableDoesNotShowPrompt() async throws {
        let ledger = Ledger(), platform = Platform(), gate = Gate(), entered = Gate()
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        await service.reloadSettings()
        platform.permission = .notDetermined
        platform.onAuthorization = { await entered.release(); await gate.wait() }
        let request = Task { await service.requestPermission() }
        await entered.wait()
        try await service.save(enabled: false, expectedRevision: 1)
        await gate.release(); await request.value
        XCTAssertEqual(platform.permissionRequests, 0)
    }

    @MainActor func testReadWriteAndFinalizationFailuresStopUntilReviewAndNeverDuplicate() async throws {
        let ledger = Ledger(), platform = Platform()
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        await ledger.failures(read: true)
        await service.process()
        XCTAssertNotNil(service.error)
        await ledger.failures()
        await service.process()
        XCTAssertTrue(platform.submitted.isEmpty)
        await service.reloadSettings()
        await ledger.failures(save: true)
        do { try await service.save(enabled: false, expectedRevision: 1); XCTFail("must fail") } catch {}
        await ledger.failures()
        await service.process()
        XCTAssertTrue(platform.submitted.isEmpty)
        await service.reloadSettings()
        await ledger.failures(finish: true)
        await service.process()
        XCTAssertEqual(platform.submitted.count, 1)
        XCTAssertTrue(platform.delivered.isEmpty)
        await ledger.failures()
        let reopened = LibraryNotificationService(persistence: ledger, platform: platform)
        await reopened.process()
        XCTAssertEqual(reopened.settings?.outcome, .unconfirmed)
        XCTAssertEqual(platform.submitted.count, 1)
    }

    @MainActor func testFailedOSSubmissionIsVisibleAndNotRetried() async throws {
        let ledger = Ledger(), platform = Platform()
        platform.onSubmit = { _ in throw LibraryNotificationError.busy }
        let service = LibraryNotificationService(persistence: ledger, platform: platform)
        await service.process(); await service.process()
        XCTAssertNotNil(service.error)
        XCTAssertEqual(service.settings?.outcome, .unconfirmed)
        XCTAssertEqual(platform.submitted.count, 1)
        platform.onSubmit = nil
        await ledger.enqueueNewBatch()
        await service.process()
        XCTAssertEqual(service.settings?.outcome, .submitted)
        XCTAssertEqual(platform.submitted.count, 2)
        XCTAssertNil(service.error)
    }

    @MainActor func testUnavailableDurableDatabaseNeverPromptsOrSubmits() async throws {
        let platform = Platform()
        let service = LibraryNotificationService(persistence: Ledger(), platform: platform, available: false)
        await service.process(); await service.requestPermission()
        do { try await service.save(enabled: true, expectedRevision: 1); XCTFail("must fail") } catch {}
        XCTAssertNotNil(service.error)
        XCTAssertTrue(platform.submitted.isEmpty)
    }

    @MainActor func testTapRoutesExactlyOneActiveSceneAfterExclusiveChangeAndRejectsUnknownPayload() {
        let router = LibraryNotificationRouter()
        XCTAssertFalse(router.request(identifier: "another-feature"))
        XCTAssertFalse(router.request(identifier: LibraryNotificationBatch.identifierPrefix + "malformed"))
        let batch = LibraryNotificationBatch(id: UUID(), chapterCount: 1, incomplete: false)
        XCTAssertTrue(router.request(identifier: batch.identifier))
        XCTAssertFalse(router.consume(active: false, libraryAvailable: true))
        XCTAssertFalse(router.consume(active: true, libraryAvailable: false))
        XCTAssertTrue(router.consume(active: true, libraryAvailable: true))
        XCTAssertFalse(router.consume(active: true, libraryAvailable: true))
        XCTAssertFalse(router.request(identifier: batch.identifier))
        XCTAssertEqual(batch.body, "1 new chapter saved. Open Updates to review.")
    }
}
