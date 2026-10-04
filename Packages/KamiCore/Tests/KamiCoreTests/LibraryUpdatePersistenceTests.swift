import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)

final class LibraryUpdatePersistenceTests: XCTestCase {
    private static let nativeID = MangaDexSource().id
    private static let fooPackage = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let fooID: Int64 = 6_351_052_922_295_965_587
    private static let fooSigner = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func add(_ title: String, to store: LibraryStore, sourceID: Int64 = nativeID) async throws -> Manga {
        let id = try await store.upsert(Manga(sourceId: sourceID, url: "/\(title)", title: title, inLibrary: true))
        let fetched = try await store.manga(id: id)
        return try XCTUnwrap(fetched)
    }

    private func chapters(_ urls: String...) -> [SChapterCompat] {
        urls.map { .init(url: $0, name: "Chapter \($0)") }
    }

    private func expect(
        _ error: LibraryUpdatePersistenceError,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(error)")
        } catch let actual as LibraryUpdatePersistenceError {
            XCTAssertEqual(actual, error)
        } catch { XCTFail("Unexpected error type \(type(of: error))") }
    }

    @discardableResult
    private func scan(
        store: LibraryStore, manga: Manga, chapters: [SChapterCompat],
        configuration: ExtensionExecutionConfiguration? = nil
    ) async throws -> LibraryUpdateCommitResult {
        let snapshot = try await store.beginLibraryUpdateScan()
        let result = try await store.recordLibraryUpdateSuccess(
            scanID: snapshot.record.scanID, manga: manga, chapters: chapters,
            expectedConfiguration: configuration
        )
        _ = try await store.finishLibraryUpdateScan(scanID: snapshot.record.scanID, status: .completed)
        return result
    }

    func testSchemaThreeMigrationSeedsKnownChaptersAndPreservesUserState() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let old = try SQLiteDatabase(path: path)
        for version in 1...3 { try old.execute(try XCTUnwrap(Migrations.steps[version])) }
        try old.execute("PRAGMA user_version=3")
        let mangaID = try old.insert(
            "INSERT INTO manga(source_id,url,title,in_library) VALUES (?,?,?,1)",
            [.int(Self.nativeID), .text("/legacy"), .text("Legacy")]
        )
        let chapterID = try old.insert("""
            INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read) VALUES (?,?,?,1,1,7)
            """, [.int(mangaID), .text("/historical"), .text("Historical")])
        let categoryID = try old.insert("INSERT INTO category(name) VALUES ('Keep category')")
        try old.run("INSERT INTO manga_category(manga_id,category_id) VALUES (?,?)", [.int(mangaID), .int(categoryID)])
        try old.run("INSERT INTO history(manga_id,chapter_id,last_read) VALUES (?,?,123)", [.int(mangaID), .int(chapterID)])

        let store = try LibraryStore(path: path)
        let begin = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(begin.items.map(\.hasSuccessfulBaseline), [true])
        let manga = try XCTUnwrap(begin.items.first?.manga)
        let result = try await store.recordLibraryUpdateSuccess(
            scanID: begin.record.scanID, manga: manga, chapters: chapters("/historical", "/new"),
            expectedConfiguration: nil
        )
        XCTAssertEqual(result.outcome, .updated(newChapters: 1, establishedBaseline: false))
        _ = try await store.finishLibraryUpdateScan(scanID: begin.record.scanID, status: .completed)
        let stored = try await store.chapters(mangaId: mangaID)
        XCTAssertEqual(stored.first?.id, chapterID)
        XCTAssertEqual(stored.first?.read, true)
        XCTAssertEqual(stored.first?.bookmark, true)
        XCTAssertEqual(stored.first?.lastPageRead, 7)
        let history = try await store.history()
        XCTAssertEqual(history.first?.2, 123)
        let library = try await store.librarySnapshot()
        XCTAssertEqual(library.categoryIDsByManga[mangaID], [categoryID])
        let reopened = try LibraryStore(path: path)
        let updates = try await reopened.libraryUpdatesSnapshot()
        XCTAssertEqual(updates.discoveries.map(\.chapter.url), ["/new"])
        XCTAssertEqual(updates.latestScan?.newChapters, 1)
        XCTAssertEqual(try old.query("PRAGMA user_version").first?.int("user_version"), 4)
    }

    func testFirstHistoricalAndEmptySuccessBothEstablishSilentBaselines() async throws {
        let store = try LibraryStore(inMemory: true)
        let historical = try await add("Historical", to: store)
        let empty = try await add("Empty", to: store)
        let first = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(first.items.map(\.hasSuccessfulBaseline), [false, false])
        _ = try await store.recordLibraryUpdateSuccess(
            scanID: first.record.scanID, manga: historical, chapters: chapters("/old"), expectedConfiguration: nil
        )
        let emptyResult = try await store.recordLibraryUpdateSuccess(
            scanID: first.record.scanID, manga: empty, chapters: [], expectedConfiguration: nil
        )
        XCTAssertEqual(emptyResult.outcome, .updated(newChapters: 0, establishedBaseline: true))
        let firstDone = try await store.finishLibraryUpdateScan(scanID: first.record.scanID, status: .completed)
        XCTAssertEqual(firstDone.checked, 2)
        XCTAssertEqual(firstDone.baselines, 2)
        XCTAssertEqual(firstDone.newChapters, 0)
        let initialUpdates = try await store.libraryUpdatesSnapshot()
        XCTAssertTrue(initialUpdates.discoveries.isEmpty)

        let next = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(next.items.map(\.hasSuccessfulBaseline), [true, true])
        _ = try await store.recordLibraryUpdateSuccess(
            scanID: next.record.scanID, manga: historical, chapters: chapters("/old", "/new"), expectedConfiguration: nil
        )
        _ = try await store.recordLibraryUpdateSuccess(
            scanID: next.record.scanID, manga: empty, chapters: chapters("/new"), expectedConfiguration: nil
        )
        let done = try await store.finishLibraryUpdateScan(scanID: next.record.scanID, status: .completed)
        XCTAssertEqual(done.newChapters, 2)
        XCTAssertEqual(done.baselines, 0)
        let updates = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(Set(updates.discoveries.map(\.id)).count, 2, "same URL on distinct manga is distinct")
    }

    func testDuplicateURLsAndRepeatedSuccessKeepFirstMetadataAndSingleDiscovery() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Duplicates", to: store)
        try await store.replaceChapters(mangaId: try XCTUnwrap(manga.id), with: [])
        let start = try await store.beginLibraryUpdateScan()
        let first = try await store.recordLibraryUpdateSuccess(
            scanID: start.record.scanID, manga: manga,
            chapters: [.init(url: "/new", name: "First"), .init(url: "/new", name: "Duplicate")],
            expectedConfiguration: nil
        )
        var changed = manga
        changed.title = "Must not replace an already committed result"
        let retry = try await store.recordLibraryUpdateSuccess(
            scanID: start.record.scanID, manga: changed, chapters: chapters("/new", "/retry"),
            expectedConfiguration: nil
        )
        XCTAssertEqual(retry, first)
        let current = try await store.chapters(mangaId: try XCTUnwrap(manga.id))
        XCTAssertEqual(current.map(\.name), ["First"])
        let stored = try await store.manga(id: try XCTUnwrap(manga.id))
        XCTAssertEqual(stored?.title, "Duplicates")
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        XCTAssertEqual(done.checked, 1)
        XCTAssertEqual(done.newChapters, 1)
        XCTAssertEqual(done.processedCount, done.total)
    }

    func testDisappearanceAndReappearanceKeepDiscoveryIdentityReadingAndHistory() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let manga = try await add("Returns", to: store)
        let mangaID = try XCTUnwrap(manga.id)
        _ = try await scan(store: store, manga: manga, chapters: [])
        _ = try await scan(
            store: store, manga: manga,
            chapters: [.init(url: "/return", name: "Returns", number: "1.5",
                             scanlators: ["Fixture team"], dateUpload: 77)]
        )
        let before = try await store.libraryUpdatesSnapshot()
        let discovery = try XCTUnwrap(before.discoveries.first)
        let chapterID = try XCTUnwrap(discovery.chapter.id)
        try await store.markRead(true, chapterId: chapterID)
        try await store.updateProgress(chapterId: chapterID, page: 9)
        try await store.recordHistory(mangaId: mangaID, chapterId: chapterID)
        try SQLiteDatabase(path: path).run("UPDATE chapter SET bookmark=1 WHERE id=?", [.int(chapterID)])
        _ = try await scan(store: store, manga: manga, chapters: [])
        let absent = try await store.libraryUpdatesSnapshot()
        XCTAssertTrue(absent.discoveries.isEmpty)
        let hiddenChapters = try await store.chapters(mangaId: mangaID)
        XCTAssertTrue(hiddenChapters.isEmpty)
        let history = try await store.history()
        XCTAssertEqual(history.first?.1.id, chapterID, "history survives an absent chapter")
        XCTAssertEqual(history.first?.1.read, true)
        XCTAssertEqual(history.first?.1.bookmark, true)
        XCTAssertEqual(history.first?.1.lastPageRead, 9)
        XCTAssertEqual(history.first?.1.name, "Returns")
        XCTAssertEqual(history.first?.1.number, 1.5)
        XCTAssertEqual(history.first?.1.scanlator, "Fixture team")
        XCTAssertEqual(history.first?.1.dateUpload, 77)

        let reopened = try LibraryStore(path: path)
        let reappeared = try await scan(store: reopened, manga: manga, chapters: chapters("/return"))
        XCTAssertEqual(reappeared.outcome, .updated(newChapters: 0, establishedBaseline: false))
        let after = try await reopened.libraryUpdatesSnapshot()
        XCTAssertEqual(after.discoveries.first?.id, discovery.id)
        XCTAssertEqual(after.discoveries.first?.detectedAt, discovery.detectedAt)
        XCTAssertEqual(after.discoveries.first?.chapter.id, chapterID)
        XCTAssertEqual(after.discoveries.first?.chapter.lastPageRead, 9)
        XCTAssertEqual(after.discoveries.first?.chapter.read, true)
        XCTAssertEqual(after.discoveries.first?.chapter.bookmark, true)
        try await reopened.setLibrary(false, mangaId: mangaID)
        let removed = try await reopened.libraryUpdatesSnapshot()
        XCTAssertTrue(removed.discoveries.isEmpty)
    }

    func testRemovalDuringRequestSkipsMetadataChaptersAndDiscoveries() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Removed", to: store)
        let mangaID = try XCTUnwrap(manga.id)
        let start = try await store.beginLibraryUpdateScan()
        let initiallyCurrent = try await store.libraryUpdateTargetIsCurrent(scanID: start.record.scanID, mangaID: mangaID)
        XCTAssertTrue(initiallyCurrent)
        try await store.setLibrary(false, mangaId: mangaID)
        let removedTarget = try await store.libraryUpdateTargetIsCurrent(scanID: start.record.scanID, mangaID: mangaID)
        XCTAssertFalse(removedTarget)
        var updated = manga
        updated.title = "Late"
        let result = try await store.recordLibraryUpdateSuccess(
            scanID: start.record.scanID, manga: updated, chapters: chapters("/late"), expectedConfiguration: nil
        )
        XCTAssertEqual(result.outcome, .skippedNotInLibrary)
        XCTAssertEqual(result.summary.skipped, 1)
        let current = try await store.manga(id: mangaID)
        XCTAssertEqual(current?.title, "Removed")
        let currentChapters = try await store.chapters(mangaId: mangaID)
        XCTAssertTrue(currentChapters.isEmpty)
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        XCTAssertEqual(done.checked, 0)
        XCTAssertEqual(done.newChapters, 0)
    }

    func testRemovalAndReadditionRejectsOldMembershipRevision() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Readded", to: store)
        let mangaID = try XCTUnwrap(manga.id)
        let start = try await store.beginLibraryUpdateScan()
        try await store.setLibrary(false, mangaId: mangaID)
        try await store.setLibrary(true, mangaId: mangaID)
        let readdedTarget = try await store.libraryUpdateTargetIsCurrent(scanID: start.record.scanID, mangaID: mangaID)
        XCTAssertFalse(readdedTarget)
        let result = try await store.recordLibraryUpdateSuccess(
            scanID: start.record.scanID, manga: manga, chapters: chapters("/stale"), expectedConfiguration: nil
        )
        XCTAssertEqual(result.outcome, .skippedNotInLibrary)
        _ = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        let next = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(next.items.first?.hasSuccessfulBaseline, false)
        _ = try await store.finishLibraryUpdateScan(scanID: next.record.scanID, status: .cancelled)
    }

    func testTerminalCancellationSurvivesReopenAndRejectsOldCallbacks() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let first = try await add("First", to: store)
        _ = try await add("Pending", to: store)
        let begin = try await store.beginLibraryUpdateScan()
        _ = try await store.recordLibraryUpdateSuccess(
            scanID: begin.record.scanID, manga: first, chapters: [], expectedConfiguration: nil
        )
        let done = try await store.finishLibraryUpdateScan(scanID: begin.record.scanID, status: .cancelled)
        XCTAssertEqual(done.checked, 1)
        XCTAssertEqual(done.cancelled, 1)
        XCTAssertEqual(done.processedCount, 2)
        let repeated = try await store.finishLibraryUpdateScan(scanID: begin.record.scanID, status: .completed)
        XCTAssertEqual(repeated, done)
        let reopened = try LibraryStore(path: path)
        let restored = try await reopened.libraryUpdatesSnapshot()
        XCTAssertEqual(restored.latestScan, done)
        let next = try await reopened.beginLibraryUpdateScan()
        await expect(.scanNotRunning) {
            _ = try await reopened.recordLibraryUpdateSuccess(
                scanID: begin.record.scanID, manga: first, chapters: self.chapters("/late"), expectedConfiguration: nil
            )
        }
        let current = try await reopened.libraryUpdatesSnapshot()
        XCTAssertTrue(current.discoveries.isEmpty)
        _ = try await reopened.finishLibraryUpdateScan(scanID: next.record.scanID, status: .cancelled)
    }

    func testExplicitRestartRecoveryPreservesCommittedCountersAndInterruptsPendingWork() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let first = try await add("Recovered", to: store)
        _ = try await add("Pending", to: store)
        let begin = try await store.beginLibraryUpdateScan()
        _ = try await store.recordLibraryUpdateSuccess(
            scanID: begin.record.scanID, manga: first, chapters: [], expectedConfiguration: nil
        )
        let reopened = try LibraryStore(path: path)
        let stillRunning = try await reopened.libraryUpdatesSnapshot()
        XCTAssertEqual(stillRunning.latestScan?.status, .running, "opening a connection must not interrupt a live scan")
        let recovery = try await reopened.recoverInterruptedLibraryUpdateScans()
        let interrupted = try XCTUnwrap(recovery)
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.checked, 1)
        XCTAssertEqual(interrupted.baselines, 1)
        XCTAssertEqual(interrupted.cancelled, 1)
        XCTAssertEqual(interrupted.processedCount, interrupted.total)
        let repeatRecovery = try await reopened.recoverInterruptedLibraryUpdateScans()
        XCTAssertEqual(repeatRecovery, interrupted)
        await expect(.scanNotRunning) {
            _ = try await store.recordLibraryUpdateSuccess(
                scanID: begin.record.scanID, manga: first, chapters: self.chapters("/late"), expectedConfiguration: nil
            )
        }
    }

    func testLedgerMetadataChaptersAndCountersRollbackTogetherOnChapterFailure() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let manga = try await add("Rollback", to: store)
        let mangaID = try XCTUnwrap(manga.id)
        try await store.replaceChapters(mangaId: mangaID, with: [])
        let start = try await store.beginLibraryUpdateScan()
        let db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TRIGGER fail_new_chapter BEFORE INSERT ON chapter
            BEGIN SELECT RAISE(ABORT,'offline fixture'); END;
            """)
        var updated = manga
        updated.title = "Must roll back"
        do {
            _ = try await store.recordLibraryUpdateSuccess(
                scanID: start.record.scanID, manga: updated, chapters: chapters("/new"), expectedConfiguration: nil
            )
            XCTFail("Expected injected SQLite failure")
        } catch is SQLiteDatabase.SQLiteError {}
        let after = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(after.latestScan?.checked, 0)
        XCTAssertEqual(after.latestScan?.newChapters, 0)
        XCTAssertTrue(after.discoveries.isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM known_chapter").isEmpty)
        let stored = try await store.manga(id: mangaID)
        XCTAssertEqual(stored?.title, "Rollback")
        try db.execute("DROP TRIGGER fail_new_chapter")
        let retry = try await store.recordLibraryUpdateSuccess(
            scanID: start.record.scanID, manga: updated, chapters: chapters("/new"), expectedConfiguration: nil
        )
        XCTAssertEqual(retry.outcome, .updated(newChapters: 1, establishedBaseline: false))
        _ = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
    }

    func testFailedAndSkippedTargetsNeverCreateBaselinesOrDiscoveriesAndDeduplicate() async throws {
        let store = try LibraryStore(inMemory: true)
        let failed = try await add("Failed", to: store)
        let skipped = try await add("Skipped", to: store)
        let pending = try await add("Pending", to: store)
        let start = try await store.beginLibraryUpdateScan()
        await expect(.scanAlreadyRunning) { _ = try await store.beginLibraryUpdateScan() }
        let failedID = try XCTUnwrap(failed.id)
        let skippedID = try XCTUnwrap(skipped.id)
        _ = try await store.recordLibraryUpdateFailure(scanID: start.record.scanID, mangaID: failedID)
        _ = try await store.recordLibraryUpdateFailure(scanID: start.record.scanID, mangaID: failedID)
        _ = try await store.recordLibraryUpdateSkip(scanID: start.record.scanID, mangaID: skippedID, reason: .onlyFetchOnce)
        await expect(.unfinishedTargets) {
            _ = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        }
        await expect(.targetAlreadyRecorded) {
            _ = try await store.recordLibraryUpdateSuccess(
                scanID: start.record.scanID, manga: failed, chapters: self.chapters("/retry"), expectedConfiguration: nil
            )
        }
        try await store.setLibrary(false, mangaId: try XCTUnwrap(pending.id))
        let summary = try await store.recordLibraryUpdateFailure(
            scanID: start.record.scanID, mangaID: try XCTUnwrap(pending.id)
        )
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(summary.checked, 0)
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        XCTAssertEqual(done.processedCount, 3)
        let next = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(next.items.map(\.hasSuccessfulBaseline), [false, false])
        _ = try await store.finishLibraryUpdateScan(scanID: next.record.scanID, status: .cancelled)
    }

    func testSnapshotRejectsAddedTargetAndForgedSourceIdentityWithoutMutations() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Captured", to: store)
        let start = try await store.beginLibraryUpdateScan()
        let added = try await add("Added later", to: store)
        await expect(.mangaNotInScan) {
            _ = try await store.recordLibraryUpdateSuccess(
                scanID: start.record.scanID, manga: added, chapters: self.chapters("/not-target"), expectedConfiguration: nil
            )
        }
        var forged = manga
        forged.url = "/different"
        await expect(.sourceIdentityMismatch) {
            _ = try await store.recordLibraryUpdateSuccess(
                scanID: start.record.scanID, manga: forged, chapters: self.chapters("/forged"), expectedConfiguration: nil
            )
        }
        let current = try await store.libraryUpdatesSnapshot()
        XCTAssertTrue(current.discoveries.isEmpty)
        XCTAssertEqual(current.latestScan?.processedCount, 0)
        _ = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .cancelled)
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    func testCancelledCallerCannotCreateBaselineOrChapterAndCancelRemainsDurable() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Cancelled task", to: store)
        let start = try await store.beginLibraryUpdateScan()
        let gate = Gate()
        let task = Task {
            await gate.wait()
            return try await store.recordLibraryUpdateSuccess(
                scanID: start.record.scanID, manga: manga,
                chapters: [SChapterCompat(url: "/cancelled", name: "Cancelled")], expectedConfiguration: nil
            )
        }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let beforeFinish = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(beforeFinish.latestScan?.processedCount, 0)
        XCTAssertTrue(beforeFinish.discoveries.isEmpty)
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .cancelled)
        XCTAssertEqual(done.cancelled, 1)
        let next = try await store.beginLibraryUpdateScan()
        XCTAssertEqual(next.items.first?.hasSuccessfulBaseline, false)
        _ = try await store.finishLibraryUpdateScan(scanID: next.record.scanID, status: .cancelled)
    }

    func testSuccessfulEmptyDetailRefreshEstablishesBaselineForNextScan() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Detail baseline", to: store)
        _ = try await store.persistSourceUpdate(manga: manga, chapters: [], expectedConfiguration: nil)
        let next = try await scan(store: store, manga: manga, chapters: chapters("/first"))
        XCTAssertEqual(next.outcome, .updated(newChapters: 1, establishedBaseline: false))
    }

    func testDetailDiscoveryIsVisibleAndNextScanDoesNotClaimItAgain() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Detail discovery", to: store)
        _ = try await store.persistSourceUpdate(manga: manga, chapters: chapters("/historical"), expectedConfiguration: nil)
        let historical = try await store.libraryUpdatesSnapshot()
        XCTAssertTrue(historical.discoveries.isEmpty)
        _ = try await store.persistSourceUpdate(
            manga: manga, chapters: chapters("/historical", "/new"), expectedConfiguration: nil
        )
        let discovered = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(discovered.discoveries.map(\.chapter.url), ["/new"])
        let next = try await scan(store: store, manga: manga, chapters: chapters("/historical", "/new"))
        XCTAssertEqual(next.outcome, .updated(newChapters: 0, establishedBaseline: false))
        XCTAssertEqual(next.summary.newChapters, 0)
        let afterScan = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(afterScan.discoveries, discovered.discoveries)
        try await store.setLibrary(false, mangaId: try XCTUnwrap(manga.id))
        _ = try await store.persistSourceUpdate(
            manga: manga, chapters: chapters("/historical", "/new", "/outside"), expectedConfiguration: nil
        )
        try await store.setLibrary(true, mangaId: try XCTUnwrap(manga.id))
        let readded = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(readded.discoveries.map(\.chapter.url), ["/new"], "outside-library refresh is silent")
    }

    func testRawChapterImportSeedsKnownWithoutGeneratingOrLosingExistingNews() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Import", to: store)
        let id = try XCTUnwrap(manga.id)
        try await store.replaceChapters(mangaId: id, with: [Chapter(url: "/imported", name: "Imported")])
        let first = try await scan(store: store, manga: manga, chapters: chapters("/imported", "/new"))
        XCTAssertEqual(first.outcome, .updated(newChapters: 1, establishedBaseline: false))
        try await store.replaceChapters(
            mangaId: id, with: [Chapter(url: "/imported", name: "Imported"), Chapter(url: "/new", name: "New"),
                               Chapter(url: "/later-import", name: "Later import")]
        )
        let next = try await scan(store: store, manga: manga, chapters: chapters("/imported", "/new", "/later-import"))
        XCTAssertEqual(next.outcome, .updated(newChapters: 0, establishedBaseline: false))
        let snapshot = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(snapshot.discoveries.map(\.chapter.url), ["/new"])
    }

    func testDiscoveryPaginationHasStableCursorAndNoMissingOrRepeatedRows() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Pages", to: store)
        _ = try await scan(store: store, manga: manga, chapters: [])
        let urls = (1...7).map { "/chapter/\($0)" }
        _ = try await scan(store: store, manga: manga, chapters: urls.map { .init(url: $0, name: $0) })
        let first = try await store.libraryUpdatesSnapshot(discoveryLimit: 3)
        XCTAssertEqual(first.discoveries.count, 3)
        XCTAssertTrue(first.hasMore)
        let firstCursor = try XCTUnwrap(first.nextCursor)
        let second = try await store.libraryUpdatesSnapshot(discoveryLimit: 3, after: firstCursor)
        XCTAssertEqual(second.discoveries.count, 3)
        XCTAssertTrue(second.hasMore)
        let secondCursor = try XCTUnwrap(second.nextCursor)
        let last = try await store.libraryUpdatesSnapshot(discoveryLimit: 3, after: secondCursor)
        XCTAssertEqual(last.discoveries.count, 1)
        XCTAssertFalse(last.hasMore)
        XCTAssertNil(last.nextCursor)
        let all = first.discoveries + second.discoveries + last.discoveries
        XCTAssertEqual(Set(all.map(\.chapter.url)), Set(urls))
        XCTAssertEqual(Set(all.map(\.id)).count, 7)
        let unchanged = try await store.libraryUpdatesSnapshot(discoveryLimit: 3)
        XCTAssertEqual(unchanged, first, "reading Updates changes no state")
    }

    func testFiniteTargetIssuesSurviveReopenAndRetainCapturedTitleAfterRemoval() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let missing = try await add("Unavailable", to: store)
        let failed = try await add("Failed", to: store)
        let pending = try await add("Cancelled", to: store)
        let start = try await store.beginLibraryUpdateScan()
        await expect(.invalidTargetReason) {
            _ = try await store.recordLibraryUpdateSkip(
                scanID: start.record.scanID, mangaID: try XCTUnwrap(missing.id), reason: .requestFailed
            )
        }
        _ = try await store.recordLibraryUpdateSkip(
            scanID: start.record.scanID, mangaID: try XCTUnwrap(missing.id), reason: .sourceUnavailable
        )
        _ = try await store.recordLibraryUpdateFailure(
            scanID: start.record.scanID, mangaID: try XCTUnwrap(failed.id), reason: .configurationChanged
        )
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .cancelled)
        XCTAssertEqual(done.skipped, 1)
        XCTAssertEqual(done.failed, 1)
        XCTAssertEqual(done.cancelled, 1)
        try SQLiteDatabase(path: path).run("DELETE FROM manga WHERE id=?", [.int(try XCTUnwrap(pending.id))])
        let reopened = try LibraryStore(path: path)
        let restored = try await reopened.libraryUpdatesSnapshot()
        XCTAssertEqual(restored.latestScan, done)
        XCTAssertEqual(Set(restored.latestScanIssues.map(\.reason)),
                       [.sourceUnavailable, .configurationChanged, .cancelled])
        let cancelledIssue = try XCTUnwrap(restored.latestScanIssues.first { $0.reason == .cancelled })
        XCTAssertEqual(cancelledIssue.title, "Cancelled")
        XCTAssertNil(cancelledIssue.manga)
        XCTAssertEqual(cancelledIssue.outcome, .cancelled)
    }

    func testDefaultFeedLimitExposesContinuationRatherThanTruncatingOldDiscoveries() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await add("Long feed", to: store)
        _ = try await scan(store: store, manga: manga, chapters: [])
        let incoming = (1...501).map { SChapterCompat(url: "/\(String(format: "%03d", $0))", name: "Chapter \($0)") }
        _ = try await scan(store: store, manga: manga, chapters: incoming)
        let first = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(first.discoveries.count, 500)
        XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.nextCursor)
        let remainder = try await store.libraryUpdatesSnapshot(after: cursor)
        XCTAssertEqual(remainder.discoveries.count, 1)
        XCTAssertFalse(remainder.hasMore)
        XCTAssertEqual(Set((first.discoveries + remainder.discoveries).map(\.id)).count, 501)
    }

    private struct FooFixture {
        let folder: URL
        let path: String
        let store: LibraryStore
        let preferences: ExtensionPreferencesService
        let admission: ExtensionAdmissionService
    }

    private func fooFixture() async throws -> FooFixture {
        let folder = try directory()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent("Tests/corpus/measurement/foolslidecustomizable.apk")))
        let apk = folder.appendingPathComponent("foo.apk")
        try Data(bytes).write(to: apk)
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let admission = ExtensionAdmissionService(store: store)
        let entry = ExtensionRepositoryIndex.Extension(
            name: "FoolSlide Customizable", packageName: Self.fooPackage, versionName: "1.6.6",
            versionCode: 6, extensionLib: "1.6", contentWarning: .mixed,
            apkURL: "https://fixtures.invalid/foo.apk",
            sources: [.init(id: Self.fooID, name: "FoolSlide", language: "other", homeURL: "https://127.0.0.1")]
        )
        _ = try await admission.admit(
            apkBytes: bytes, extension: entry, apkPath: apk.path,
            repositoryURL: "https://fixtures.invalid/index.pb", repositorySigningKey: Self.fooSigner
        )
        let preferences = ExtensionPreferencesService(store: store)
        let empty = try await preferences.configuration(packageName: Self.fooPackage)
        _ = try await preferences.saveConfiguration(
            snapshot: empty, userValues: [.baseURL: .string("https://deployment.invalid"), .adult: .boolean(false)]
        )
        return FooFixture(folder: folder, path: path, store: store, preferences: preferences, admission: admission)
    }

    private func execution(_ f: FooFixture) async throws -> ExtensionExecutionConfiguration {
        let admission = try await f.admission.restore(packageName: Self.fooPackage)
        return try await f.preferences.loadForExecution(admission: admission)
    }

    func testStalePreferenceTokenRollsBackEveryScanWriteAndFreshTokenCanDiscover() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await execution(f)
        let manga = try await add("Foo", to: f.store, sourceID: Self.fooID)
        let mangaID = try XCTUnwrap(manga.id)
        try await f.store.replaceChapters(mangaId: mangaID, with: [])
        let begin = try await f.store.beginLibraryUpdateScan()
        let previous = try await f.preferences.configuration(packageName: Self.fooPackage)
        _ = try await f.preferences.saveConfiguration(
            snapshot: previous, userValues: [.baseURL: .string("https://deployment.invalid"), .adult: .boolean(true)]
        )
        var updated = manga
        updated.title = "Stale metadata"
        do {
            _ = try await f.store.recordLibraryUpdateSuccess(
                scanID: begin.record.scanID, manga: updated, chapters: chapters("/stale"), expectedConfiguration: token
            )
            XCTFail("Expected stale configuration")
        } catch let error as ExtensionPreferencesError { XCTAssertEqual(error, .staleConfiguration) }
        let unchanged = try await f.store.manga(id: mangaID)
        XCTAssertEqual(unchanged?.title, "Foo")
        let snapshot = try await f.store.libraryUpdatesSnapshot()
        XCTAssertEqual(snapshot.latestScan?.checked, 0)
        XCTAssertTrue(snapshot.discoveries.isEmpty)
        XCTAssertTrue(try SQLiteDatabase(path: f.path).query("SELECT * FROM known_chapter").isEmpty)
        _ = try await f.store.recordLibraryUpdateFailure(scanID: begin.record.scanID, mangaID: mangaID)
        _ = try await f.store.finishLibraryUpdateScan(scanID: begin.record.scanID, status: .completed)
        let fresh = try await execution(f)
        let result = try await scan(store: f.store, manga: manga, chapters: chapters("/fresh"), configuration: fresh)
        XCTAssertEqual(result.outcome, .updated(newChapters: 1, establishedBaseline: false))
    }

    func testDisabledInstallationAndMissingTokenCannotWriteScanResults() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await execution(f)
        let manga = try await add("Disabled Foo", to: f.store, sourceID: Self.fooID)
        let begin = try await f.store.beginLibraryUpdateScan()
        do {
            _ = try await f.store.recordLibraryUpdateSuccess(
                scanID: begin.record.scanID, manga: manga, chapters: chapters("/bypass"), expectedConfiguration: nil
            )
            XCTFail("Downloaded source requires an execution token")
        } catch let error as SourceUpdatePersistenceError { XCTAssertEqual(error, .configurationRequired) }
        try await f.store.setExtensionEnabled(false, packageName: Self.fooPackage)
        do {
            _ = try await f.store.recordLibraryUpdateSuccess(
                scanID: begin.record.scanID, manga: manga, chapters: chapters("/disabled"), expectedConfiguration: token
            )
            XCTFail("Expected stale installation")
        } catch let error as ExtensionPreferencesError { XCTAssertEqual(error, .staleInstallation) }
        let snapshot = try await f.store.libraryUpdatesSnapshot()
        XCTAssertEqual(snapshot.latestScan?.processedCount, 0)
        XCTAssertTrue(snapshot.discoveries.isEmpty)
        let current = try await f.store.chapters(mangaId: try XCTUnwrap(manga.id))
        XCTAssertTrue(current.isEmpty)
        _ = try await f.store.finishLibraryUpdateScan(scanID: begin.record.scanID, status: .cancelled)
    }
}

#endif
