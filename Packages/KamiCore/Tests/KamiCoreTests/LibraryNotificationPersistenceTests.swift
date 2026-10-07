import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

#if canImport(SQLite3)
final class LibraryNotificationPersistenceTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Notifications-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manga(_ store: LibraryStore) async throws -> Manga {
        let id = try await store.upsert(Manga(sourceId: MangaDexSource().id, url: "/sensitive", title: "Private manga title", inLibrary: true))
        let value = try await store.manga(id: id)
        return try XCTUnwrap(value)
    }
    private func scan(_ store: LibraryStore, _ manga: Manga, _ urls: [String], finish: Bool = true) async throws -> UUID {
        let scan = try await store.beginLibraryUpdateScan()
        _ = try await store.recordLibraryUpdateSuccess(scanID: scan.record.scanID, manga: manga,
            chapters: urls.map { SChapterCompat(url: $0, name: "Private chapter name") }, expectedConfiguration: nil)
        if finish { _ = try await store.finishLibraryUpdateScan(scanID: scan.record.scanID, status: .completed) }
        return scan.record.scanID
    }
    private func enable(_ store: LibraryStore) async throws -> Int64 {
        let old = try await store.libraryNotificationSettings()
        return try await store.saveLibraryNotificationSettings(enabled: true, expectedRevision: old.revision).revision
    }

    func testSchemaEightUpgradeStartsOffAndPreservesReaderAndRotation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v8.sqlite").path, db = try SQLiteDatabase(path: path)
        for version in 1...8 { try db.execute(try XCTUnwrap(Migrations.steps[version])) }
        try db.execute("PRAGMA user_version=8")
        let id = try db.insert("INSERT INTO manga(source_id,url,title,in_library,last_library_update_attempt) VALUES (1,'/x','Existing',1,73)")
        try db.run("INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read) VALUES (?,'/c','Chapter',1,1,42)", [.int(id)])
        let store = try LibraryStore(path: path)
        let settings = try await store.libraryNotificationSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.batch)
        let chapters = try await store.chapters(mangaId: id)
        XCTAssertEqual(chapters.first?.lastPageRead, 42)
        XCTAssertEqual(chapters.first?.read, true)
        XCTAssertEqual(chapters.first?.bookmark, true)
        XCTAssertEqual(try db.query("SELECT last_library_update_attempt FROM manga").first?.int64("last_library_update_attempt"), 73)
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), Migrations.latest)
    }

    func testEnableExcludesPreexistingAndAlreadyStartedScansAndFirstBaseline() async throws {
        let store = try LibraryStore(inMemory: true), manga = try await manga(store)
        _ = try await scan(store, manga, ["/one"])
        let active = try await scan(store, manga, ["/one", "/two"], finish: false)
        let revision = try await enable(store)
        _ = try await store.finishLibraryUpdateScan(scanID: active, status: .completed)
        let old = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(old)
        let secondID = try await store.upsert(Manga(sourceId: MangaDexSource().id, url: "/second", title: "Baseline", inLibrary: true))
        let snapshot = try await store.beginLibraryUpdateScan()
        let secondValue = try await store.manga(id: secondID)
        let second = try XCTUnwrap(secondValue)
        _ = try await store.recordLibraryUpdateSuccess(scanID: snapshot.record.scanID, manga: second,
            chapters: [.init(url: "/first", name: "First")], expectedConfiguration: nil)
        _ = try await store.finishLibraryUpdateScan(scanID: snapshot.record.scanID, status: .cancelled)
        let baseline = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(baseline)
    }

    func testCountsOnlyNewExactIdentitiesAndConsumesNoChangeScans() async throws {
        let store = try LibraryStore(inMemory: true), manga = try await manga(store)
        let revision = try await enable(store)
        _ = try await scan(store, manga, ["/one"])
        let baseline = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(baseline)
        _ = try await scan(store, manga, ["/one", "/caf\u{e9}", "/cafe\u{301}"])
        let value = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        let batch = try XCTUnwrap(value)
        XCTAssertEqual(batch.chapterCount, 2)
        XCTAssertFalse(batch.incomplete)
        XCTAssertFalse(batch.body.contains("Private"))
        try await store.finishLibraryNotificationBatch(id: batch.id, outcome: .submitted)
        _ = try await scan(store, manga, ["/one", "/caf\u{e9}", "/cafe\u{301}"])
        let none = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(none)
    }

    func testPartialCommitSurvivesRecoveryAndClaimCannotBeRepeatedAfterReopen() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recover.sqlite").path
        let store = try LibraryStore(path: path), manga = try await manga(store)
        let revision = try await enable(store)
        _ = try await scan(store, manga, ["/one"])
        _ = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        _ = try await scan(store, manga, ["/one", "/two"], finish: false)
        let whileRunning = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(whileRunning)
        let reopened = try LibraryStore(path: path)
        _ = try await reopened.recoverInterruptedLibraryUpdateScans()
        let value = try await reopened.claimLibraryNotificationBatch(expectedRevision: revision)
        let batch = try XCTUnwrap(value)
        XCTAssertEqual(batch.chapterCount, 1)
        XCTAssertTrue(batch.incomplete)
        let reopenedAgain = try LibraryStore(path: path)
        do { _ = try await reopenedAgain.claimLibraryNotificationBatch(expectedRevision: revision); XCTFail("Must reconcile first") }
        catch { XCTAssertEqual(error as? LibraryNotificationError, .busy) }
        try await reopenedAgain.finishLibraryNotificationBatch(id: batch.id, outcome: .unconfirmed)
        let repeated = try await reopenedAgain.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(repeated)
        let saved = try await reopenedAgain.chapters(mangaId: manga.id!)
        XCTAssertEqual(saved.count, 2)
    }

    func testSettingsABAAndDisableDiscardOldAttemptWithoutReplayingBacklog() async throws {
        let store = try LibraryStore(inMemory: true), manga = try await manga(store)
        let revision = try await enable(store)
        _ = try await scan(store, manga, ["/one"])
        _ = try await scan(store, manga, ["/one", "/two"])
        let value = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        let oldBatch = try XCTUnwrap(value)
        let off = try await store.saveLibraryNotificationSettings(enabled: false, expectedRevision: revision)
        _ = try await scan(store, manga, ["/one", "/two", "/three"])
        let on = try await store.saveLibraryNotificationSettings(enabled: true, expectedRevision: off.revision)
        do { _ = try await store.saveLibraryNotificationSettings(enabled: false, expectedRevision: revision); XCTFail("Stale editor") }
        catch { XCTAssertEqual(error as? LibraryNotificationError, .settingsChanged) }
        try await store.finishLibraryNotificationBatch(id: oldBatch.id, outcome: .submitted)
        let settings = try await store.libraryNotificationSettings()
        XCTAssertEqual(settings, on)
        let backlog = try await store.claimLibraryNotificationBatch(expectedRevision: on.revision)
        XCTAssertNil(backlog)
    }

    func testClaimFailureRollsBackWatermarkAndPreservesSavedChapters() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("failure.sqlite").path
        let store = try LibraryStore(path: path), manga = try await manga(store), db = try SQLiteDatabase(path: path)
        let revision = try await enable(store)
        _ = try await scan(store, manga, ["/one"])
        _ = try await scan(store, manga, ["/one", "/two"])
        try db.execute("CREATE TRIGGER reject_alert BEFORE UPDATE OF batch_id ON library_notification_state BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        do { _ = try await store.claimLibraryNotificationBatch(expectedRevision: revision); XCTFail("Must roll back") } catch {}
        XCTAssertEqual(try db.query("SELECT scan_cursor FROM library_notification_state").first?.int64("scan_cursor"), 0)
        try db.execute("DROP TRIGGER reject_alert")
        let claimed = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertEqual(claimed?.chapterCount, 1)
        let saved = try await store.chapters(mangaId: manga.id!)
        XCTAssertEqual(saved.count, 2)
    }

    func testBoundedPassAdvancesEmptyScansAndLeavesLaterDiscoveriesAvailable() async throws {
        let store = try LibraryStore(inMemory: true), manga = try await manga(store)
        let revision = try await enable(store)
        for _ in 0..<100 { _ = try await scan(store, manga, ["/one"]) }
        _ = try await scan(store, manga, ["/one", "/two"])
        let first = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertNil(first)
        let second = try await store.claimLibraryNotificationBatch(expectedRevision: revision)
        XCTAssertEqual(second?.chapterCount, 1)
    }
}
#endif
