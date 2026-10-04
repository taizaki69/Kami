import Foundation
import XCTest
@testable import KamiCore

#if canImport(SQLite3)
final class ReadingStatePersistenceTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let path: String
        let db: SQLiteDatabase
        let store: LibraryStore
        let mangaID: Int64
        let chapterID: Int64
        let sourceID: Int64
        let mangaURL: String
    }

    private func fixture(sourceID: Int64 = 17, mangaURL: String = "/manga",
                         chapterURL: String = "/chapter", inLibrary: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Reading-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let db = try SQLiteDatabase(path: path)
        let mangaID = try db.insert("""
            INSERT INTO manga(source_id,url,title,in_library,alt_titles,genres,date_added,date_updated)
            VALUES (?,?,'Saved manga',?,'["Alias"]','["Adventure"]',123,456)
            """, [.int(sourceID), .text(mangaURL), .bool(inLibrary)])
        let chapterID = try db.insert("""
            INSERT INTO chapter(manga_id,url,name,source_order,number,date_upload,bookmark,last_page_read)
            VALUES (?,?,'Saved chapter',9,2.25,1700000000123,1,7)
            """, [.int(mangaID), .text(chapterURL)])
        return Fixture(directory: directory, path: path, db: db, store: store, mangaID: mangaID,
                       chapterID: chapterID, sourceID: sourceID, mangaURL: mangaURL)
    }

    private func snapshot(_ f: Fixture) async throws -> MangaReadingSnapshot {
        let value = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL,
                                                     requestedChapterID: f.chapterID)
        return try XCTUnwrap(value)
    }

    private func target(_ f: Fixture) async throws -> ChapterWriteTarget {
        let value = try await snapshot(f)
        return try XCTUnwrap(value.target(for: f.chapterID))
    }

    private func expect(_ expected: ReadingStateError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ReadingStateError, expected, file: file, line: line) }
    }

    private func stored(_ f: Fixture) throws -> (page: Int64, read: Int64, bookmark: Int64, history: Int64) {
        let row = try XCTUnwrap(f.db.query("SELECT last_page_read,read,bookmark FROM chapter WHERE id=?",
                                          [.int(f.chapterID)]).first)
        let history = try XCTUnwrap(f.db.query("SELECT COUNT(*) AS n FROM history").first?.int64("n"))
        return (try XCTUnwrap(row.int64("last_page_read")), try XCTUnwrap(row.int64("read")),
                try XCTUnwrap(row.int64("bookmark")), history)
    }

    func testMigrationSixSeedsOnceAndReopeningDoesNotRotateEpoch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let initial = try await snapshot(f)
        let bytes = try XCTUnwrap(f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch"))
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(try f.db.query("PRAGMA user_version").first?.int("user_version"), Migrations.latest)
        let reopened = try LibraryStore(path: f.path)
        let again = try await reopened.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL)
        XCTAssertEqual(again?.epoch, initial.epoch)
        XCTAssertEqual(try f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch"), bytes)
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM library_data_state").first?.int("n"), 1)
        let oldTarget = try XCTUnwrap(initial.target(for: f.chapterID))
        await expect(.foreignTarget) { _ = try await reopened.validateReadingTarget(oldTarget) }
        XCTAssertEqual(try stored(f).page, 7)
    }

    func testMigrationFiveUpgradePreservesExistingReaderRowsAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Reading-Legacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite").path
        let db = try SQLiteDatabase(path: path)
        for version in 1...5 { try db.execute(try XCTUnwrap(Migrations.steps[version])) }
        try db.execute("PRAGMA user_version=5")
        let mangaID = try db.insert("INSERT INTO manga(source_id,url,title) VALUES (17,'/m','Keep')")
        let chapterID = try db.insert("INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read,is_current) VALUES (?,'/c','Keep',1,1,7,0)", [.int(mangaID)])
        try db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,456)", [.int(mangaID), .int(chapterID)])
        let store = try LibraryStore(path: path)
        let value = try await store.readingSnapshot(sourceID: 17, mangaURL: "/m", requestedChapterID: chapterID)
        XCTAssertTrue(try XCTUnwrap(value?.requestedChapter).read)
        XCTAssertTrue(try XCTUnwrap(value?.requestedChapter).bookmark)
        XCTAssertEqual(value?.requestedChapter?.lastPageRead, 7)
        XCTAssertTrue(try XCTUnwrap(value).currentChapters.isEmpty)
        XCTAssertEqual(try db.query("SELECT read_duration FROM history").first?.int("read_duration"), 456)
        XCTAssertEqual(try db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch")?.count, 16)
    }

    func testEpochSchemaEnforcesSingletonBlobTypeAndSixteenBytes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for sql in ["UPDATE library_data_state SET epoch=randomblob(15)",
                    "UPDATE library_data_state SET epoch='1234567890123456'",
                    "INSERT INTO library_data_state(singleton,epoch) VALUES (2,randomblob(16))"] {
            XCTAssertThrowsError(try f.db.execute(sql))
        }
        XCTAssertEqual(try f.db.query("SELECT length(epoch) AS n FROM library_data_state").first?.int("n"), 16)
    }

    func testMissingAndCorruptEpochFailClosedWithoutReseeding() async throws {
        for sql in ["DELETE FROM library_data_state", "UPDATE library_data_state SET epoch=randomblob(17)",
                    "UPDATE library_data_state SET epoch='1234567890123456'", "UPDATE library_data_state SET epoch=17"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let retained = try await target(f)
            try f.db.execute("PRAGMA ignore_check_constraints=ON")
            try f.db.execute(sql)
            await expect(.invalidStoredData) { _ = try await self.snapshot(f) }
            await expect(.invalidStoredData) { _ = try await f.store.validateReadingTarget(retained) }
            await expect(.invalidStoredData) {
                try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
            }
            let state = try stored(f)
            XCTAssertEqual(state.page, 7); XCTAssertEqual(state.read, 0); XCTAssertEqual(state.history, 0)
            if sql == "DELETE FROM library_data_state" {
                XCTAssertTrue(try f.db.query("SELECT 1 FROM library_data_state").isEmpty)
            }
        }
    }

    func testSnapshotIssuesTargetsForCurrentDownloadedAndRequestedHiddenUnion() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let hiddenDownloaded = try f.db.insert("INSERT INTO chapter(manga_id,url,name,source_order,is_current) VALUES (?,'/downloaded','Offline',2,0)", [.int(f.mangaID)])
        let hiddenRequested = try f.db.insert("INSERT INTO chapter(manga_id,url,name,source_order,is_current) VALUES (?,'/history','Historical',1,0)", [.int(f.mangaID)])
        _ = try f.db.insert("INSERT INTO chapter(manga_id,url,name,is_current) VALUES (?,'/unselected','Hidden',0)", [.int(f.mangaID)])
        try f.db.run("""
            INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,
                state,revision,queue_order,created_at,updated_at)
            VALUES (?,?,?,?, '','',2,1,1,0,0)
            """, [.text(UUID().uuidString), .int(hiddenDownloaded), .int(f.mangaID), .int(f.sourceID)])
        let result = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL,
                                                      requestedChapterID: hiddenRequested)
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value.currentChapters.compactMap(\.id), [f.chapterID])
        XCTAssertEqual(value.downloadedChapters.compactMap(\.id), [hiddenDownloaded])
        XCTAssertEqual(value.requestedChapter?.id, hiddenRequested)
        XCTAssertEqual(Set(value.targets.keys), [f.chapterID, hiddenDownloaded, hiddenRequested])
        XCTAssertEqual(value.manga.altTitles, ["Alias"])
        XCTAssertEqual(value.manga.genres, ["Adventure"])
        for issued in value.targets.values {
            XCTAssertEqual(issued.epoch, value.epoch)
            XCTAssertEqual(issued.mangaID, f.mangaID)
            XCTAssertEqual(issued.sourceID, f.sourceID)
            XCTAssertEqual(Data(issued.mangaURL.utf8), Data(f.mangaURL.utf8))
            let chapter = try await f.store.validateReadingTarget(issued)
            XCTAssertEqual(chapter.id, issued.chapterID)
            XCTAssertEqual(Data(chapter.url.utf8), Data(issued.chapterURL.utf8))
        }
    }

    func testHiddenNonlibraryReaderNeedsNoSourceRegistrationOrDownload() async throws {
        let f = try fixture(sourceID: Int64.min, inLibrary: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE chapter SET is_current=0")
        let value = try await snapshot(f)
        XCTAssertFalse(value.manga.inLibrary)
        XCTAssertTrue(value.currentChapters.isEmpty)
        XCTAssertTrue(value.downloadedChapters.isEmpty)
        let retained = try XCTUnwrap(value.target(for: f.chapterID))
        let result = try await f.store.commitReadingProgress(target: retained, page: 3, reachedEnd: false, lastRead: 0)
        XCTAssertEqual(result.chapter.id, f.chapterID)
        XCTAssertEqual(result.lastRead, 0)
        XCTAssertEqual(result.readDuration, 0)
    }

    func testRequestedChapterMustBelongToExactInitialManga() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let other = try f.db.insert("INSERT INTO manga(source_id,url) VALUES (17,'/other')")
        let otherChapter = try f.db.insert("INSERT INTO chapter(manga_id,url,name) VALUES (?,'/other','Other')", [.int(other)])
        await expect(.identityChanged) {
            _ = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL, requestedChapterID: otherChapter)
        }
        await expect(.chapterNotFound) {
            _ = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL, requestedChapterID: 999)
        }
        let absent = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: "/absent")
        XCTAssertNil(absent)
    }

    func testExactUTF8IdentitiesDoNotCollapseCanonicalUnicodeSpellings() async throws {
        let composed = "/caf\u{00e9}", decomposed = "/cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let f = try fixture(mangaURL: composed, chapterURL: composed)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let otherID = try f.db.insert("INSERT INTO manga(source_id,url,title) VALUES (?,?,'Other spelling')", [.int(f.sourceID), .text(decomposed)])
        let siblingID = try f.db.insert("INSERT INTO chapter(manga_id,url,name) VALUES (?,?,'Other chapter spelling')", [.int(f.mangaID), .text(decomposed)])
        let first = try await snapshot(f)
        let second = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: decomposed)
        XCTAssertEqual(first.manga.id, f.mangaID)
        XCTAssertEqual(second?.manga.id, otherID)
        XCTAssertEqual(first.targets.count, 2)
        XCTAssertNotEqual(first.target(for: f.chapterID), first.target(for: siblingID))
        let retained = try XCTUnwrap(first.target(for: f.chapterID))
        try f.db.run("DELETE FROM chapter WHERE id=?", [.int(siblingID)])
        try f.db.run("UPDATE chapter SET url=? WHERE id=?", [.text(decomposed), .int(f.chapterID)])
        await expect(.identityChanged) { _ = try await f.store.validateReadingTarget(retained) }
    }

    func testSignedSourceAndLargeOrderPageHistoryValuesRemainExact() async throws {
        let f = try fixture(sourceID: Int64.min)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE chapter SET source_order=?,last_page_read=?", [.int(Int64.min), .int(4_294_967_311)])
        try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,?,?)",
                     [.int(f.mangaID), .int(f.chapterID), .int(Int64.max - 1), .int(Int64.max)])
        let value = try await snapshot(f)
        XCTAssertEqual(value.requestedChapter?.sourceOrder, Int.min)
        XCTAssertEqual(value.requestedChapter?.lastPageRead, 4_294_967_311)
        XCTAssertEqual(value.requestedChapter?.dateUpload, 1_700_000_000_123)
        let result = try await f.store.commitReadingProgress(target: try XCTUnwrap(value.target(for: f.chapterID)),
                                                              page: Int64.max, reachedEnd: false, lastRead: Int64.max)
        XCTAssertEqual(result.chapter.lastPageRead, Int.max)
        XCTAssertEqual(result.lastRead, Int64.max)
        XCTAssertEqual(result.readDuration, Int64.max)
    }

    func testTargetsRejectAnotherStoreAndCopiedDatabaseWithSameEpoch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let value = try await snapshot(f)
        let retained = try XCTUnwrap(value.target(for: f.chapterID))
        let copyPath = f.directory.appendingPathComponent("copy.sqlite").path
        try f.db.run("VACUUM INTO ?", [.text(copyPath)])
        for store in [try LibraryStore(path: f.path), try LibraryStore(path: copyPath)] {
            let otherSnapshot = try await store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL)
            XCTAssertEqual(otherSnapshot?.epoch, value.epoch)
            await expect(.foreignTarget) { _ = try await store.validateReadingTarget(retained) }
            await expect(.foreignTarget) { _ = try await store.refreshReadingSnapshot(validating: retained) }
            await expect(.foreignTarget) { _ = try await store.setChapterRead(true, target: retained) }
            await expect(.foreignTarget) {
                try await store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
            }
        }
        XCTAssertEqual(try stored(f).history, 0)
        XCTAssertEqual(try stored(f).page, 7)
    }

    func testChangedDurableEpochRejectsRetainedAndQueuedWritesWithoutRebase() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try await snapshot(f)
        let retained = try XCTUnwrap(before.target(for: f.chapterID))
        // Models the epoch rotation inside a future restore transaction. The
        // archive and public LibraryStore API never expose this operation.
        try f.db.run("UPDATE library_data_state SET epoch=?", [.blob(Array(repeating: 0xA5, count: 16))])
        await expect(.staleEpoch) { _ = try await f.store.validateReadingTarget(retained) }
        await expect(.staleEpoch) { _ = try await f.store.refreshReadingSnapshot(validating: retained) }
        await expect(.staleEpoch) { _ = try await f.store.setChapterRead(true, target: retained) }
        let queued = Task { try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10) }
        await expect(.staleEpoch) { _ = try await queued.value }
        XCTAssertEqual(try stored(f).page, 7)
        XCTAssertEqual(try stored(f).history, 0)
        let reopened = try await snapshot(f)
        XCTAssertNotEqual(reopened.epoch, before.epoch)
        let fresh = try XCTUnwrap(reopened.target(for: f.chapterID))
        let result = try await f.store.commitReadingProgress(target: fresh, page: 3, reachedEnd: false, lastRead: 10)
        XCTAssertEqual(result.chapter.lastPageRead, 3)
        await expect(.staleEpoch) { _ = try await f.store.validateReadingTarget(retained) }
    }

    func testReboundPhysicalIDsRejectChangedSourceURLsAndChapterParent() async throws {
        for mutation in ["UPDATE manga SET source_id=18", "UPDATE manga SET url='/replacement'",
                         "UPDATE chapter SET url='/replacement'", "UPDATE chapter SET manga_id=999"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let retained = try await target(f)
            try f.db.run("INSERT INTO manga(id,source_id,url) VALUES (999,17,'/other')")
            let reboundID = mutation.hasPrefix("UPDATE manga") ? f.mangaID : f.chapterID
            try f.db.run(mutation + " WHERE id=?", [.int(reboundID)])
            await expect(.identityChanged) { _ = try await f.store.validateReadingTarget(retained) }
            await expect(.identityChanged) { _ = try await f.store.refreshReadingSnapshot(validating: retained) }
            await expect(.identityChanged) { _ = try await f.store.setChapterRead(true, target: retained) }
            await expect(.identityChanged) {
                try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
            }
            XCTAssertEqual(try stored(f).page, 7)
            XCTAssertEqual(try stored(f).read, 0)
            XCTAssertEqual(try stored(f).history, 0)
        }
    }

    func testCanonicallyEquivalentMangaURLReplacementStillRejectsOldTarget() async throws {
        let f = try fixture(mangaURL: "/caf\u{00e9}")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        try f.db.run("UPDATE manga SET url=?", [.text("/cafe\u{0301}")])
        await expect(.identityChanged) { _ = try await f.store.validateReadingTarget(retained) }
        await expect(.identityChanged) {
            try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
        }
    }

    func testDeletedRowsFailBeforeAnyMutation() async throws {
        for (sql, expected) in [("DELETE FROM chapter", ReadingStateError.chapterNotFound),
                                ("DELETE FROM manga", .mangaNotFound)] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let retained = try await target(f)
            try f.db.execute(sql)
            await expect(expected) { _ = try await f.store.validateReadingTarget(retained) }
            await expect(expected) {
                try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
            }
            XCTAssertTrue(try f.db.query("SELECT 1 FROM history").isEmpty)
        }
    }

    func testMetadataRefreshAndHiddenTransitionPreserveCapturedIdentity() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        try f.db.run("UPDATE manga SET title='Refreshed',in_library=0")
        try f.db.run("UPDATE chapter SET name='Updated chapter',source_order=2,is_current=0,read=1,last_page_read=4")
        let fresh = try await f.store.validateReadingTarget(retained)
        XCTAssertEqual(fresh.name, "Updated chapter")
        XCTAssertEqual(fresh.lastPageRead, 4)
        XCTAssertTrue(fresh.read)
        let refreshed = try await f.store.refreshReadingSnapshot(validating: retained)
        XCTAssertEqual(refreshed.manga.title, "Refreshed")
        XCTAssertFalse(refreshed.manga.inLibrary)
        XCTAssertTrue(refreshed.currentChapters.isEmpty)
        XCTAssertEqual(refreshed.requestedChapter, fresh)
        XCTAssertEqual(refreshed.target(for: f.chapterID), retained)
    }

    func testProgressCanGoBackwardPreservesReadBookmarkAndDuration() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE chapter SET read=1")
        try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,5000000001)", [.int(f.mangaID), .int(f.chapterID)])
        let retained = try await target(f)
        let result = try await f.store.commitReadingProgress(target: retained, page: 0, reachedEnd: false, lastRead: 456)
        XCTAssertEqual(result.chapter.lastPageRead, 0)
        XCTAssertTrue(result.chapter.read)
        XCTAssertTrue(result.chapter.bookmark)
        XCTAssertEqual(result.lastRead, 456)
        XCTAssertEqual(result.readDuration, 5_000_000_001)
        XCTAssertEqual(try stored(f).history, 1)
        XCTAssertEqual(try f.db.query("SELECT last_read FROM history").first?.int64("last_read"), 456)
    }

    func testEndSetsReadWhileOrdinaryProgressKeepsUnreadAndManualUnread() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        let first = try await f.store.commitReadingProgress(target: retained, page: 8, reachedEnd: false, lastRead: 100)
        XCTAssertFalse(first.chapter.read)
        let end = try await f.store.commitReadingProgress(target: retained, page: 9, reachedEnd: true, lastRead: 101)
        XCTAssertTrue(end.chapter.read)
        let unread = try await f.store.setChapterRead(false, target: retained)
        XCTAssertFalse(unread.read)
        XCTAssertEqual(unread.lastPageRead, 9)
        let again = try await f.store.commitReadingProgress(target: retained, page: 2, reachedEnd: false, lastRead: 102)
        XCTAssertFalse(again.chapter.read)
        XCTAssertTrue(again.chapter.bookmark)
        XCTAssertEqual(again.readDuration, 0)
    }

    func testManualReadTogglePreservesProgressAndExistingHistory() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        let read = try await f.store.setChapterRead(true, target: retained)
        XCTAssertTrue(read.read)
        XCTAssertTrue(read.bookmark)
        XCTAssertEqual(read.lastPageRead, 7)
        XCTAssertEqual(try stored(f).history, 0, "manual toggle must not invent reading history")
        try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,456)", [.int(f.mangaID), .int(f.chapterID)])
        _ = try await f.store.setChapterRead(false, target: retained)
        let history = try XCTUnwrap(f.db.query("SELECT last_read,read_duration FROM history").first)
        XCTAssertEqual(history.int64("last_read"), 123)
        XCTAssertEqual(history.int64("read_duration"), 456)
    }

    func testInjectedHistoryFailureRollsBackPageReadAndHistoryTogether() async throws {
        for existingHistory in [false, true] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            if existingHistory {
                try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,456)", [.int(f.mangaID), .int(f.chapterID)])
            }
            let retained = try await target(f)
            try f.db.execute("CREATE TRIGGER injected_history_failure BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture failure with private detail'); END;")
            await expect(.storageUnavailable) {
                try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 777)
            }
            let state = try stored(f)
            XCTAssertEqual(state.page, 7); XCTAssertEqual(state.read, 0); XCTAssertEqual(state.bookmark, 1)
            XCTAssertEqual(state.history, existingHistory ? 1 : 0)
            if existingHistory {
                XCTAssertEqual(try f.db.query("SELECT last_read FROM history").first?.int64("last_read"), 123)
                XCTAssertEqual(try f.db.query("SELECT read_duration FROM history").first?.int64("read_duration"), 456)
            }
            try f.db.execute("DROP TRIGGER injected_history_failure")
            let committed = try await f.store.commitReadingProgress(target: retained, page: 2, reachedEnd: false, lastRead: 888)
            XCTAssertEqual(committed.chapter.lastPageRead, 2, "failed transaction must release the connection")
        }
    }

    func testIdentityChangeInsideHistoryTriggerRollsBackEntireProgressWrite() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        try f.db.execute("""
            CREATE TRIGGER injected_identity_change AFTER INSERT ON history BEGIN
                UPDATE chapter SET url='/replacement' WHERE id=NEW.chapter_id;
            END;
            """)
        await expect(.identityChanged) {
            try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
        }
        XCTAssertEqual(try stored(f).page, 7)
        XCTAssertEqual(try stored(f).read, 0)
        XCTAssertEqual(try stored(f).history, 0)
        XCTAssertEqual(try f.db.query("SELECT url FROM chapter").first?.string("url"), "/chapter")
    }

    func testNegativeProgressInputsAreRejectedWithoutChangingState() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        for (page, date) in [(Int64(-1), Int64(1)), (Int64(1), Int64(-1))] {
            await expect(.invalidInput) {
                try await f.store.commitReadingProgress(target: retained, page: page, reachedEnd: true, lastRead: date)
            }
        }
        XCTAssertEqual(try stored(f).page, 7)
        XCTAssertEqual(try stored(f).history, 0)
    }

    func testCancellationRejectsSnapshotsValidationAndWritesWithoutMutation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let retained = try await target(f)
        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: f.mangaURL) },
            { _ = try await f.store.validateReadingTarget(retained) },
            { _ = try await f.store.refreshReadingSnapshot(validating: retained) },
            { _ = try await f.store.setChapterRead(true, target: retained) },
            { try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10) },
        ]
        for operation in operations {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await operation()
            }
            do { try await task.value; XCTFail("cancelled reader operation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(try stored(f).page, 7)
        XCTAssertEqual(try stored(f).read, 0)
        XCTAssertEqual(try stored(f).history, 0)
        let result = try await f.store.commitReadingProgress(target: retained, page: 1, reachedEnd: false, lastRead: 10)
        XCTAssertEqual(result.chapter.lastPageRead, 1)
    }

    func testMalformedStoredScalarTypesAreRejectedBeforeModelsAreMapped() async throws {
        for sql in ["UPDATE manga SET source_id='wrong'", "UPDATE manga SET title=zeroblob(1048576)",
                    "UPDATE manga SET status=99", "UPDATE manga SET in_library=2", "UPDATE manga SET initialized=2",
                    "UPDATE manga SET date_added='wrong'", "UPDATE manga SET date_updated=-1",
                    "UPDATE manga SET update_strategy='UNKNOWN'", "UPDATE chapter SET source_order=zeroblob(1048576)",
                    "UPDATE chapter SET read=2", "UPDATE chapter SET bookmark=2", "UPDATE chapter SET last_page_read=-1",
                    "UPDATE chapter SET date_upload=-1", "UPDATE chapter SET number='wrong'"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            // Request the manga by its unchanged source/URL even if its source
            // column is corrupted, so strict guarded validation is also tested.
            let retained = try await target(f)
            try f.db.execute(sql)
            if sql.contains("source_id=") {
                await expect(.invalidStoredData) { _ = try await f.store.validateReadingTarget(retained) }
            } else {
                await expect(.invalidStoredData) { _ = try await self.snapshot(f) }
            }
            XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM history").first?.int64("n"), 0)
        }
    }

    func testStoredUTF8NULAndIdentityControlsNeverBecomeReplacementOrTruncatedText() async throws {
        for sql in ["UPDATE manga SET url=CAST(X'2F6D00FF' AS TEXT)", "UPDATE chapter SET url=CAST(X'C328' AS TEXT)",
                    "UPDATE chapter SET url=CAST(X'2F630A' AS TEXT)", "UPDATE chapter SET url=''",
                    "UPDATE manga SET title=CAST(X'410042' AS TEXT)", "UPDATE chapter SET name=CAST(X'410042' AS TEXT)",
                    "UPDATE chapter SET scanlator=CAST(X'C328' AS TEXT)", "UPDATE manga SET genres='[\"\\u0000\"]'",
                    "UPDATE manga SET alt_titles='[\"\\uD800\"]'"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let retained = try await target(f)
            try f.db.execute(sql)
            if sql.contains("manga SET url=") {
                await expect(.invalidStoredData) { _ = try await f.store.validateReadingTarget(retained) }
            } else {
                await expect(.invalidStoredData) { _ = try await self.snapshot(f) }
            }
        }
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE manga SET description=?", [.text("Valid\nmetadata\tspacing")])
        let withSpacing = try await snapshot(f)
        XCTAssertEqual(withSpacing.manga.descriptionText, "Valid\nmetadata\tspacing")
        for bad in ["", "/m\0tail", "/m\n", String(repeating: "x", count: 4_097)] {
            await expect(.invalidInput) { _ = try await f.store.readingSnapshot(sourceID: f.sourceID, mangaURL: bad) }
        }
    }

    func testFieldByteLimitsAreInclusiveAndUseUTF8ByteCounts() async throws {
        let f = try fixture(mangaURL: String(repeating: "m", count: 4_096), chapterURL: String(repeating: "c", count: 4_096))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE manga SET title=?,description=?", [.text(String(repeating: "t", count: 8_192)),
                                                               .text(String(repeating: "d", count: 262_144))])
        try f.db.run("UPDATE chapter SET name=?", [.text(String(repeating: "n", count: 8_192))])
        let exact = try await snapshot(f)
        XCTAssertNotNil(exact.target(for: f.chapterID))
        try f.db.run("UPDATE chapter SET name=?", [.text(String(repeating: "漫", count: 2_731))])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
        try f.db.run("UPDATE chapter SET name='Chapter'")
        try f.db.run("UPDATE manga SET description=?", [.text(String(repeating: "d", count: 262_145))])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
    }

    func testArrayCountsStringsAndInvalidJSONAreBoundedBeforeFoundationDecodesThem() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let exact = "[" + Array(repeating: "\"\"", count: 256).joined(separator: ",") + "]"
        try f.db.run("UPDATE manga SET alt_titles=?", [.text(exact)])
        let inclusive = try await snapshot(f)
        XCTAssertEqual(inclusive.manga.altTitles.count, 256)
        let tooMany = "[" + Array(repeating: "\"\"", count: 257).joined(separator: ",") + "]"
        try f.db.run("UPDATE manga SET alt_titles=?", [.text(tooMany)])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
        try f.db.run("UPDATE manga SET alt_titles=?", [.text("[\"" + String(repeating: "a", count: 8_193) + "\"]")])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
        for broken in ["broken", "[null]", "[[]]", "{\"a\":1,\"\\u0061\":2}"] {
            try f.db.run("UPDATE manga SET alt_titles=?", [.text(broken)])
            await expect(.invalidStoredData) { _ = try await self.snapshot(f) }
        }
    }

    func testSelectedChapterCountIsBoundedBeforeMaterialization() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("""
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<19999)
            INSERT INTO chapter(manga_id,url,name,source_order) SELECT ?,'/c/'||x,'c',x FROM n
            """, [.int(f.mangaID)])
        let exact = try await snapshot(f)
        XCTAssertEqual(exact.currentChapters.count, 20_000)
        XCTAssertEqual(exact.targets.count, 20_000)
        try f.db.run("INSERT INTO chapter(manga_id,url,name) VALUES (?,'/excess','excess')", [.int(f.mangaID)])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
        let retained = try XCTUnwrap(exact.target(for: f.chapterID))
        // Saving one valid retained row does not need to materialize the entire
        // neighbour list again just because it grew beyond the snapshot bound.
        let result = try await f.store.commitReadingProgress(target: retained, page: 2, reachedEnd: false, lastRead: 10)
        XCTAssertEqual(result.chapter.lastPageRead, 2)
    }

    func testCumulativeDecodedStringBudgetRejectsACollectionOfIndividuallyValidNames() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("""
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<4096)
            INSERT INTO chapter(manga_id,url,name) SELECT ?,'/c/'||x,? FROM n
            """, [.int(f.mangaID), .text(String(repeating: "n", count: 8_192))])
        await expect(.limitExceeded) { _ = try await self.snapshot(f) }
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM chapter").first?.int64("n"), 4_097)
        XCTAssertTrue(try f.db.query("SELECT 1 FROM history").isEmpty)
    }

    func testCorruptHistoryParentTypesAndTimesRollBackProgress() async throws {
        for corruption in ["UPDATE history SET manga_id=999", "UPDATE history SET last_read='wrong'",
                           "UPDATE history SET read_duration=-1", "UPDATE history SET last_read=-1"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let retained = try await target(f)
            try f.db.run("INSERT INTO manga(id,source_id,url) VALUES (999,18,'/other')")
            try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,456)", [.int(f.mangaID), .int(f.chapterID)])
            try f.db.execute(corruption)
            await expect(.invalidStoredData) {
                try await f.store.commitReadingProgress(target: retained, page: 99, reachedEnd: true, lastRead: 10)
            }
            XCTAssertEqual(try stored(f).page, 7)
            XCTAssertEqual(try stored(f).read, 0)
        }
    }

    func testCorruptDownloadedParentCannotInventAnOfflineNeighbour() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("INSERT INTO manga(id,source_id,url) VALUES (999,17,'/other')")
        try f.db.run("""
            INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,
                state,revision,queue_order,created_at,updated_at) VALUES (?,?,999,17,'','',2,1,1,0,0)
            """, [.text(UUID().uuidString), .int(f.chapterID)])
        await expect(.invalidStoredData) { _ = try await self.snapshot(f) }
    }

    func testFiniteLocalizedErrorsContainNoStoredURLOrSQLDetails() {
        for failure in [ReadingStateError.storageUnavailable, .invalidStoredData, .limitExceeded, .invalidInput,
                        .foreignTarget, .staleEpoch, .identityChanged, .mangaNotFound, .chapterNotFound] {
            let message = failure.localizedDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertLessThan(message.utf8.count, 180)
            XCTAssertFalse(message.contains("SELECT"))
            XCTAssertFalse(message.contains("/chapter"))
        }
    }
}
#endif
