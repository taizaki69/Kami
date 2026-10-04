import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)
final class DownloadPersistenceTests: XCTestCase {
    private static let nativeID = MangaDexSource().id
    private static let fooPackage = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let fooID: Int64 = 6_351_052_922_295_965_587
    private static let fooSigner = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private static let pageHash = String(repeating: "a", count: 64)
    private static let manifestHash = String(repeating: "b", count: 64)

    private struct Fixture {
        let folder: URL
        let path: String
        let store: LibraryStore
        let mangaID: Int64
        let chapters: [Chapter]
    }

    private func fixture(
        policy: DownloadPolicy = .init(), chapterCount: Int = 3,
        sourceID: Int64 = nativeID
    ) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Downloads-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path, downloadPolicy: policy)
        let mangaID = try await store.upsert(Manga(sourceId: sourceID, url: "/manga", title: "Keep", inLibrary: true))
        try await store.replaceChapters(mangaId: mangaID, with: (0..<chapterCount).map {
            Chapter(mangaId: mangaID, sourceOrder: $0, url: "/chapter/\($0)", name: "Chapter \($0)",
                    read: $0 == 0, bookmark: $0 == 0, lastPageRead: $0 == 0 ? 7 : 0)
        })
        let chapters = try await store.chapters(mangaId: mangaID)
        return Fixture(folder: folder, path: path, store: store, mangaID: mangaID, chapters: chapters)
    }

    private func expect(
        _ expected: DownloadPersistenceError, _ operation: () async throws -> Void
    ) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? DownloadPersistenceError, expected) }
    }

    private func attempt(
        _ f: Fixture, index: Int = 0, configuration: ExtensionExecutionConfiguration? = nil
    ) async throws -> DownloadAttempt {
        let item = try await f.store.enqueueDownload(
            chapterID: try XCTUnwrap(f.chapters[index].id), expectedConfiguration: configuration)
        return try await f.store.beginDownloadAttempt(jobID: item.jobID, expectedConfiguration: configuration)
    }

    private func receipt(_ attempt: DownloadAttempt, pages: [DownloadPageReceipt]) -> DownloadManifestReceipt {
        .init(identity: attempt.identity, pages: pages, totalBytes: pages.reduce(0) { $0 + $1.byteCount },
              manifestSHA256: Self.manifestHash)
    }

    @discardableResult
    private func prepare(
        _ f: Fixture, attempt: DownloadAttempt, bytes: Int64 = 4
    ) async throws -> DownloadManifestReceipt {
        let page = DownloadPageReceipt(ordinal: 0, byteCount: bytes, sha256: Self.pageHash)
        _ = try await f.store.setDownloadPageCount(attempt: attempt, pageCount: 1)
        _ = try await f.store.commitDownloadPage(attempt: attempt, receipt: page)
        let manifest = receipt(attempt, pages: [page])
        _ = try await f.store.prepareDownload(attempt: attempt, manifestReceipt: manifest)
        return manifest
    }

    func testLegacyStatesMigrateToUnverifiedPauseAndPreserveDomain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Download-Migration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("legacy.sqlite").path
        let old = try SQLiteDatabase(path: path)
        for version in 1...4 { try old.execute(try XCTUnwrap(Migrations.steps[version])) }
        try old.execute("PRAGMA user_version=4")
        let mangaID = try old.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,?,?,1)",
                                     [.int(Self.nativeID), .text("/legacy"), .text("Legacy")])
        var chapterIDs: [Int64] = []
        for state in 0...3 {
            let chapterID = try old.insert("""
                INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read) VALUES (?,?,?,1,1,7)
                """, [.int(mangaID), .text("/chapter/\(state)"), .text("Legacy \(state)")])
            try old.run("INSERT INTO download(chapter_id,state,progress,tries,queue_order) VALUES (?,?,1,3,?)",
                        [.int(chapterID), .int(state), .int(state)])
            chapterIDs.append(chapterID)
        }
        let categoryID = try old.insert("INSERT INTO category(name) VALUES ('Keep category')")
        try old.run("INSERT INTO manga_category(manga_id,category_id) VALUES (?,?)", [.int(mangaID), .int(categoryID)])
        try old.run("INSERT INTO history(manga_id,chapter_id,last_read) VALUES (?,?,123)",
                    [.int(mangaID), .int(chapterIDs[2])])
        let store = try LibraryStore(path: path)
        let snapshot = try await store.downloadsSnapshot()
        XCTAssertEqual(snapshot.items.count, 4)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.state == .paused && $0.reason == .legacyUnverified })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.contentIdentity == nil && $0.storedBytes == 0 })
        for id in chapterIDs {
            let offline = try await store.offlineChapter(chapterID: id)
            XCTAssertNil(offline)
        }
        let chapters = try await store.chapters(mangaId: mangaID)
        XCTAssertTrue(chapters.allSatisfy { $0.read && $0.bookmark && $0.lastPageRead == 7 })
        let history = try await store.history()
        XCTAssertEqual(history.first?.1.id, chapterIDs[2])
        let library = try await store.librarySnapshot()
        XCTAssertEqual(library.categoryIDsByManga[mangaID], [categoryID])
        let repeated = try LibraryStore(path: path)
        let reopened = try await repeated.downloadsSnapshot()
        XCTAssertEqual(reopened.items.map(\.jobID), snapshot.items.map(\.jobID))
        let queued = try await store.retryDownload(jobID: snapshot.items[2].jobID, expectedConfiguration: nil)
        XCTAssertEqual(queued.state, .queued)
        let fresh = try await store.beginDownloadAttempt(jobID: queued.jobID, expectedConfiguration: nil)
        XCTAssertEqual(fresh.identity.chapterID, chapterIDs[2])
        let located = try await repeated.downloadItem(jobID: fresh.jobID)
        XCTAssertEqual(located?.contentIdentity, fresh.identity)
        let deleted = try await repeated.deleteDownload(jobID: fresh.jobID)
        XCTAssertEqual(deleted.cleanup, [fresh.identity])
        try await repeated.acknowledgeDownloadCleanup(identity: fresh.identity)
        let absent = try await store.downloadItem(jobID: fresh.jobID)
        XCTAssertNil(absent)
        let preserved = try await store.downloadTarget(chapterID: fresh.identity.chapterID)
        XCTAssertTrue(preserved.chapter.read)
        XCTAssertEqual(try old.query("PRAGMA user_version").first?.int("user_version"), 5)
    }

    func testIdempotentQueuePaginationAndNextQueuedIgnoreFinishedUIPage() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        var ids: [UUID] = []
        for chapter in f.chapters {
            let item = try await f.store.enqueueDownload(chapterID: try XCTUnwrap(chapter.id), expectedConfiguration: nil)
            ids.append(item.jobID)
        }
        let duplicate = try await f.store.enqueueDownload(chapterID: try XCTUnwrap(f.chapters[0].id), expectedConfiguration: nil)
        XCTAssertEqual(duplicate.jobID, ids[0])
        let first = try await f.store.downloadsSnapshot(limit: 1)
        XCTAssertTrue(first.hasMore)
        let second = try await f.store.downloadsSnapshot(limit: 1, after: try XCTUnwrap(first.nextCursor))
        let third = try await f.store.downloadsSnapshot(limit: 1, after: try XCTUnwrap(second.nextCursor))
        XCTAssertEqual((first.items + second.items + third.items).map(\.jobID), ids)
        XCTAssertFalse(third.hasMore)
        for id in ids.prefix(2) {
            let token = try await f.store.beginDownloadAttempt(jobID: id, expectedConfiguration: nil)
            let manifest = try await prepare(f, attempt: token)
            _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest)
        }
        let uiFirst = try await f.store.downloadsSnapshot(limit: 1)
        XCTAssertEqual(uiFirst.items.first?.state, .finished)
        let queued = try await f.store.nextQueuedDownload()
        XCTAssertEqual(queued?.jobID, ids[2])
        XCTAssertEqual(uiFirst.summary.finished, 2)
        XCTAssertEqual(uiFirst.summary.queued, 1)
    }

    func testQueueLimitAndSingleActiveAttemptRejectWithoutLosingExistingRows() async throws {
        let f = try await fixture(policy: .init(maximumJobs: 2))
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let first = try await attempt(f)
        let second = try await f.store.enqueueDownload(chapterID: try XCTUnwrap(f.chapters[1].id), expectedConfiguration: nil)
        await expect(.queueLimitExceeded) {
            _ = try await f.store.enqueueDownload(chapterID: try XCTUnwrap(f.chapters[2].id), expectedConfiguration: nil)
        }
        await expect(.activeAttemptExists) {
            _ = try await f.store.beginDownloadAttempt(jobID: second.jobID, expectedConfiguration: nil)
        }
        let unchanged = try await f.store.downloadsSnapshot()
        XCTAssertEqual(unchanged.summary.totalJobs, 2)
        XCTAssertEqual(unchanged.items.first?.contentIdentity, first.identity)
    }

    func testPauseCleanupAndRetryUseNewAttemptAndOldAckCannotResetIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let old = try await attempt(f)
        _ = try await prepare(f, attempt: old)
        let paused = try await f.store.pauseDownload(jobID: old.jobID)
        XCTAssertEqual(paused.cleanup, [old.identity])
        XCTAssertEqual(paused.item?.storedBytes, 4)
        await expect(.cleanupPending) { _ = try await f.store.retryDownload(jobID: old.jobID, expectedConfiguration: nil) }
        let wrong = DownloadContentIdentity(jobID: old.jobID, attemptID: old.attemptID, mangaID: old.identity.mangaID,
                                            chapterID: old.identity.chapterID, sourceID: old.identity.sourceID,
                                            mangaURLDigest: Self.pageHash, chapterURLDigest: old.identity.chapterURLDigest)
        await expect(.sourceIdentityMismatch) { try await f.store.acknowledgeDownloadCleanup(identity: wrong) }
        try await f.store.acknowledgeDownloadCleanup(identity: old.identity)
        _ = try await f.store.retryDownload(jobID: old.jobID, expectedConfiguration: nil)
        let fresh = try await f.store.beginDownloadAttempt(jobID: old.jobID, expectedConfiguration: nil)
        XCTAssertNotEqual(fresh.attemptID, old.attemptID)
        XCTAssertGreaterThan(fresh.revision, old.revision)
        try await f.store.acknowledgeDownloadCleanup(identity: old.identity)
        let current = try await f.store.downloadItem(jobID: fresh.jobID)
        XCTAssertEqual(current?.contentIdentity, fresh.identity)
        await expect(.staleAttempt) { _ = try await f.store.commitDownloadPage(attempt: old, receipt: .init(ordinal: 0, byteCount: 4, sha256: Self.pageHash)) }
    }

    func testReceiptsAreBoundedAndIdempotentWithAtomicChapterBudget() async throws {
        let f = try await fixture(policy: .init(maximumPageCount: 2, maximumPageBytes: 8, maximumChapterBytes: 10))
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        await expect(.pageLimitExceeded) { _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 0) }
        await expect(.pageLimitExceeded) { _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 3) }
        _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 2)
        for invalid in [
            DownloadPageReceipt(ordinal: -1, byteCount: 4, sha256: Self.pageHash),
            .init(ordinal: 2, byteCount: 4, sha256: Self.pageHash),
            .init(ordinal: 0, byteCount: 0, sha256: Self.pageHash),
            .init(ordinal: 0, byteCount: 9, sha256: Self.pageHash),
            .init(ordinal: 0, byteCount: 4, sha256: "INVALID")
        ] { await expect(.invalidReceipt) { _ = try await f.store.commitDownloadPage(attempt: token, receipt: invalid) } }
        let page = DownloadPageReceipt(ordinal: 0, byteCount: 6, sha256: Self.pageHash)
        _ = try await f.store.commitDownloadPage(attempt: token, receipt: page)
        let repeated = try await f.store.commitDownloadPage(attempt: token, receipt: page)
        XCTAssertEqual(repeated.completedPages, 1)
        XCTAssertEqual(repeated.storedBytes, 6)
        await expect(.invalidReceipt) {
            _ = try await f.store.commitDownloadPage(attempt: token, receipt: .init(ordinal: 0, byteCount: 5, sha256: Self.pageHash))
        }
        await expect(.chapterLimitExceeded) {
            _ = try await f.store.commitDownloadPage(attempt: token, receipt: .init(ordinal: 1, byteCount: 6, sha256: Self.pageHash))
        }
        let unchanged = try await f.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(unchanged?.storedBytes, 6)
        XCTAssertEqual(unchanged?.completedPages, 1)
    }

    func testManifestCannotPrepareMissingChangedOrForeignPages() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 2)
        let p0 = DownloadPageReceipt(ordinal: 0, byteCount: 4, sha256: Self.pageHash)
        let p1 = DownloadPageReceipt(ordinal: 1, byteCount: 3, sha256: Self.pageHash)
        _ = try await f.store.commitDownloadPage(attempt: token, receipt: p0)
        await expect(.incompletePages) { _ = try await f.store.prepareDownload(attempt: token, manifestReceipt: self.receipt(token, pages: [p0])) }
        _ = try await f.store.commitDownloadPage(attempt: token, receipt: p1)
        let foreign = DownloadContentIdentity(jobID: token.jobID, attemptID: UUID(), mangaID: f.mangaID,
                                               chapterID: token.identity.chapterID, sourceID: Self.nativeID,
                                               mangaURLDigest: token.identity.mangaURLDigest,
                                               chapterURLDigest: token.identity.chapterURLDigest)
        for bad in [
            DownloadManifestReceipt(identity: token.identity, pages: [p1,p0], totalBytes: 7, manifestSHA256: Self.manifestHash),
            .init(identity: token.identity, pages: [p0,p1], totalBytes: 8, manifestSHA256: Self.manifestHash),
            .init(identity: token.identity, pages: [p0,p1], totalBytes: 7, manifestSHA256: "bad"),
            .init(identity: foreign, pages: [p0,p1], totalBytes: 7, manifestSHA256: Self.manifestHash)
        ] { await expect(.manifestMismatch) { _ = try await f.store.prepareDownload(attempt: token, manifestReceipt: bad) } }
        let good = receipt(token, pages: [p0,p1])
        _ = try await f.store.prepareDownload(attempt: token, manifestReceipt: good)
        _ = try await f.store.prepareDownload(attempt: token, manifestReceipt: good)
        await expect(.invalidState) { _ = try await f.store.commitDownloadPage(attempt: token, receipt: p0) }
        let finished = try await f.store.completeDownload(attempt: token, manifestReceipt: good)
        XCTAssertEqual(finished.state, .finished)
    }

    func testCancellationBeforeCompleteRejectsLatePublicationAndPersistsCleanup() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        let manifest = try await prepare(f, attempt: token)
        let cancelled = try await f.store.cancelDownload(jobID: token.jobID)
        XCTAssertEqual(cancelled.item?.state, .cancelled)
        XCTAssertEqual(cancelled.cleanup, [token.identity])
        await expect(.staleAttempt) { _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest) }
        let reopened = try LibraryStore(path: f.path)
        let item = try await reopened.downloadItem(jobID: token.jobID)
        let offline = try await reopened.offlineChapter(chapterID: token.identity.chapterID)
        let cleanup = try await reopened.pendingDownloadCleanup()
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(item?.storedBytes, 4)
        XCTAssertNil(offline)
        XCTAssertEqual(cleanup, [token.identity])
        let repeated = try await reopened.cancelDownload(jobID: token.jobID)
        XCTAssertEqual(repeated.item?.revision, item?.revision)
    }

    func testRestartNeverPromotesPreparedFilesAndPreservesCleanupByteAccounting() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        let manifest = try await prepare(f, attempt: token)
        let reopened = try LibraryStore(path: f.path)
        let recovery = try await reopened.recoverInterruptedDownloads()
        XCTAssertEqual(recovery.interruptedJobs, 1)
        XCTAssertEqual(recovery.cleanup, [token.identity])
        let snapshot = try await reopened.downloadsSnapshot()
        XCTAssertEqual(snapshot.items.first?.reason, .interrupted)
        XCTAssertEqual(snapshot.summary.storedBytes, 4)
        XCTAssertEqual(snapshot.summary.cleanupBytes, 4)
        let offline = try await reopened.offlineChapter(chapterID: token.identity.chapterID)
        XCTAssertNil(offline)
        await expect(.staleAttempt) { _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest) }
        let repeated = try await reopened.recoverInterruptedDownloads()
        XCTAssertEqual(repeated.interruptedJobs, 0)
        try await reopened.acknowledgeDownloadCleanup(identity: token.identity)
        let clean = try await reopened.downloadsSnapshot()
        XCTAssertEqual(clean.summary.storedBytes, 0)
        XCTAssertEqual(clean.summary.cleanupBytes, 0)
    }

    func testRemovalAndReadditionRejectsOldAttemptAndRetainsDomain() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        let manifest = try await prepare(f, attempt: token)
        try await f.store.setLibrary(false, mangaId: f.mangaID)
        try await f.store.setLibrary(true, mangaId: f.mangaID)
        await expect(.staleAttempt) { _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest) }
        let item = try await f.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(item?.reason, .mangaRemoved)
        XCTAssertEqual(item?.chapter.lastPageRead, 7)
        XCTAssertTrue(item?.manga.inLibrary == true)
    }

    func testDisappearanceInvalidatesActiveButKeepsCompletedHiddenChapter() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let finished = try await attempt(f)
        let manifest = try await prepare(f, attempt: finished)
        _ = try await f.store.completeDownload(attempt: finished, manifestReceipt: manifest)
        let active = try await attempt(f, index: 1)
        _ = try await f.store.setDownloadPageCount(attempt: active, pageCount: 1)
        try await f.store.replaceChapters(mangaId: f.mangaID, with: [])
        await expect(.staleAttempt) {
            _ = try await f.store.commitDownloadPage(attempt: active, receipt: .init(ordinal: 0, byteCount: 4, sha256: Self.pageHash))
        }
        let local = try await f.store.offlineChapter(chapterID: finished.identity.chapterID)
        XCTAssertEqual(local?.identity, finished.identity)
        XCTAssertFalse(local?.isCurrentChapter ?? true)
        XCTAssertEqual(local?.chapter.lastPageRead, 7)
        let hidden = try await f.store.downloadTarget(chapterID: finished.identity.chapterID)
        XCTAssertFalse(hidden.isCurrentChapter)
        let downloaded = try await f.store.downloadedChapters(mangaID: f.mangaID)
        XCTAssertEqual(downloaded.map(\.id), [finished.identity.chapterID])
    }

    func testPageAndCounterWriteRollbackTogetherOnSQLiteFailure() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 1)
        let db = try SQLiteDatabase(path: f.path)
        try db.execute("""
            CREATE TRIGGER fail_counter BEFORE UPDATE OF completed_pages ON download_job
            BEGIN SELECT RAISE(ABORT,'private fixture'); END;
            """)
        do {
            _ = try await f.store.commitDownloadPage(attempt: token, receipt: .init(ordinal: 0, byteCount: 4, sha256: Self.pageHash))
            XCTFail("Expected SQLite rollback")
        } catch is SQLiteDatabase.SQLiteError {}
        XCTAssertTrue(try db.query("SELECT * FROM download_page").isEmpty)
        let unchanged = try await f.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(unchanged?.completedPages, 0)
        XCTAssertEqual(unchanged?.storedBytes, 0)
        try db.execute("DROP TRIGGER fail_counter")
        let manifest = try await prepare(f, attempt: token)
        _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest)
    }

    func testQueuedFailureUsesRevisionCASAndDoesNotOverwriteCancellationOrRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let item = try await f.store.enqueueDownload(chapterID: try XCTUnwrap(f.chapters[0].id), expectedConfiguration: nil)
        _ = try await f.store.failQueuedDownload(jobID: item.jobID, expectedRevision: item.revision, reason: .sourceUnavailable)
        _ = try await f.store.retryDownload(jobID: item.jobID, expectedConfiguration: nil)
        await expect(.staleAttempt) {
            _ = try await f.store.failQueuedDownload(jobID: item.jobID, expectedRevision: item.revision, reason: .storageUnavailable)
        }
        let fetched = try await f.store.downloadItem(jobID: item.jobID)
        let fresh = try XCTUnwrap(fetched)
        _ = try await f.store.cancelDownload(jobID: fresh.jobID)
        await expect(.staleAttempt) {
            _ = try await f.store.failQueuedDownload(jobID: fresh.jobID, expectedRevision: fresh.revision, reason: .sourceUnavailable)
        }
        let final = try await f.store.downloadItem(jobID: item.jobID)
        XCTAssertEqual(final?.state, .cancelled)
    }

    func testExplicitDeletionPreservesReadingHistoryCategoriesAndManga() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let category = try await f.store.createCategory(name: "Keep category")
        try await f.store.setCategories([try XCTUnwrap(category.id)], mangaId: f.mangaID)
        let token = try await attempt(f)
        let manifest = try await prepare(f, attempt: token)
        _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest)
        try await f.store.recordHistory(mangaId: f.mangaID, chapterId: token.identity.chapterID)
        let deletion = try await f.store.deleteDownload(jobID: token.jobID)
        XCTAssertEqual(deletion.item?.state, .deleting)
        XCTAssertEqual(deletion.cleanup, [token.identity])
        let unavailable = try await f.store.offlineChapter(chapterID: token.identity.chapterID)
        XCTAssertNil(unavailable)
        let stillStored = try await f.store.downloadsSnapshot()
        XCTAssertEqual(stillStored.summary.storedBytes, 4)
        try await f.store.acknowledgeDownloadCleanup(identity: token.identity)
        let absent = try await f.store.downloadItem(jobID: token.jobID)
        XCTAssertNil(absent)
        let domain = try await f.store.librarySnapshot()
        XCTAssertEqual(domain.manga.count, 1)
        XCTAssertEqual(domain.categoryIDsByManga[f.mangaID], [try XCTUnwrap(category.id)])
        let chapters = try await f.store.chapters(mangaId: f.mangaID)
        XCTAssertTrue(chapters[0].read)
        XCTAssertTrue(chapters[0].bookmark)
        XCTAssertEqual(chapters[0].lastPageRead, 7)
        let history = try await f.store.history()
        XCTAssertEqual(history.first?.1.id, token.identity.chapterID)
        XCTAssertEqual(history.first?.1.lastPageRead, 7)
    }

    func testBatchAvailabilityAndLibraryAggregateIncludeHiddenButRejectOversizedSelection() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        let manifest = try await prepare(f, attempt: token)
        _ = try await f.store.completeDownload(attempt: token, manifestReceipt: manifest)
        try await f.store.replaceChapters(mangaId: f.mangaID, with: [])
        let states = try await f.store.downloadChapterStates(chapterIDs: [token.identity.chapterID, token.identity.chapterID])
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[token.identity.chapterID]?.state, .finished)
        let counts = try await f.store.downloadedChapterCountsByManga()
        XCTAssertEqual(counts[f.mangaID], 1)
        await expect(.selectionTooLarge) {
            _ = try await f.store.downloadChapterStates(chapterIDs: Array(repeating: token.identity.chapterID, count: 501))
        }
        try await f.store.setLibrary(false, mangaId: f.mangaID)
        let removedCounts = try await f.store.downloadedChapterCountsByManga()
        XCTAssertNil(removedCounts[f.mangaID])
        let local = try await f.store.offlineChapter(chapterID: token.identity.chapterID)
        XCTAssertNotNil(local)
    }

    private struct FooFixture {
        let base: Fixture
        let preferences: ExtensionPreferencesService
        let admission: ExtensionAdmissionService
        let bytes: [UInt8]
        let apk: URL
        let entry: ExtensionRepositoryIndex.Extension
    }

    private func fooFixture() async throws -> FooFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Download-Foo-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent("Tests/corpus/measurement/foolslidecustomizable.apk")))
        let apk = folder.appendingPathComponent("foo.apk")
        try Data(bytes).write(to: apk)
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let admission = ExtensionAdmissionService(store: store)
        let entry = ExtensionRepositoryIndex.Extension(
            name: "FoolSlide", packageName: Self.fooPackage, versionName: "1.6.6", versionCode: 6,
            extensionLib: "1.6", contentWarning: .mixed, apkURL: "https://fixtures.invalid/foo.apk",
            sources: [.init(id: Self.fooID, name: "FoolSlide", language: "other", homeURL: "https://127.0.0.1")])
        _ = try await admission.admit(apkBytes: bytes, extension: entry, apkPath: apk.path,
                                      repositoryURL: "https://fixtures.invalid/index.pb", repositorySigningKey: Self.fooSigner)
        let preferences = ExtensionPreferencesService(store: store)
        let empty = try await preferences.configuration(packageName: Self.fooPackage)
        _ = try await preferences.saveConfiguration(snapshot: empty, userValues: [
            .baseURL: .string("https://deployment.invalid"), .adult: .boolean(false)
        ])
        let mangaID = try await store.upsert(Manga(sourceId: Self.fooID, url: "/foo", title: "Foo", inLibrary: true))
        try await store.replaceChapters(mangaId: mangaID, with: (0..<2).map {
            Chapter(mangaId: mangaID, sourceOrder: $0, url: "/foo/chapter/\($0)", name: "Foo \($0)",
                    read: $0 == 0, bookmark: $0 == 0, lastPageRead: $0 == 0 ? 7 : 0)
        })
        let chapters = try await store.chapters(mangaId: mangaID)
        let base = Fixture(folder: folder, path: path, store: store, mangaID: mangaID, chapters: chapters)
        return FooFixture(base: base, preferences: preferences, admission: admission, bytes: bytes, apk: apk, entry: entry)
    }

    private func execution(_ f: FooFixture) async throws -> ExtensionExecutionConfiguration {
        let admission = try await f.admission.restore(packageName: Self.fooPackage)
        return try await f.preferences.loadForExecution(admission: admission)
    }

    func testDownloadedProfileRequiresAuthenticationAndConfigurationToken() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        do {
            _ = try await f.base.store.enqueueDownload(chapterID: try XCTUnwrap(f.base.chapters[0].id), expectedConfiguration: nil)
            XCTFail("Profile downloads require an execution token")
        } catch let error as SourceUpdatePersistenceError { XCTAssertEqual(error, .configurationRequired) }
        let configuration = try await execution(f)
        try await f.base.store.setExtensionEnabled(false, packageName: Self.fooPackage)
        do {
            _ = try await f.base.store.enqueueDownload(chapterID: try XCTUnwrap(f.base.chapters[0].id), expectedConfiguration: configuration)
            XCTFail("Disabled configuration cannot queue traffic")
        } catch let error as ExtensionPreferencesError { XCTAssertEqual(error, .staleInstallation) }
        let snapshot = try await f.base.store.downloadsSnapshot()
        XCTAssertEqual(snapshot.summary.totalJobs, 0)
    }

    func testDisableEnableABAInvalidatesActiveAndQueuedAndPreventsLateComplete() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        let config = try await execution(f)
        let token = try await attempt(f.base, configuration: config)
        let manifest = try await prepare(f.base, attempt: token)
        let queued = try await f.base.store.enqueueDownload(chapterID: try XCTUnwrap(f.base.chapters[1].id), expectedConfiguration: config)
        try await f.base.store.setExtensionEnabled(false, packageName: Self.fooPackage)
        try await f.base.store.setExtensionEnabled(true, packageName: Self.fooPackage)
        // The exact installed/document token is equal again. Its old attempt
        // remains revoked by the durable revision, independent of that ABA.
        try await f.base.store.verifyExtensionExecutionConfiguration(config)
        await expect(.staleAttempt) { _ = try await f.base.store.completeDownload(attempt: token, manifestReceipt: manifest) }
        let snapshot = try await f.base.store.downloadsSnapshot()
        XCTAssertTrue(snapshot.items.allSatisfy { $0.state == .paused && $0.reason == .configurationChanged })
        XCTAssertEqual(snapshot.summary.cleanupBytes, 4)
        await expect(.invalidState) { _ = try await f.base.store.beginDownloadAttempt(jobID: queued.jobID, expectedConfiguration: config) }
    }

    func testPreferenceSaveInvalidatesAttemptsInSameTransaction() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        let config = try await execution(f)
        let token = try await attempt(f.base, configuration: config)
        let manifest = try await prepare(f.base, attempt: token)
        let previous = try await f.preferences.configuration(packageName: Self.fooPackage)
        _ = try await f.preferences.saveConfiguration(snapshot: previous, userValues: [
            .baseURL: .string("https://deployment.invalid"), .adult: .boolean(true)
        ])
        let item = try await f.base.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(item?.state, .paused)
        XCTAssertEqual(item?.reason, .configurationChanged)
        await expect(.staleAttempt) { _ = try await f.base.store.completeDownload(attempt: token, manifestReceipt: manifest) }
    }

    func testPreferenceFailureRollsBackDocumentAttemptAndCleanupTogether() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        let config = try await execution(f)
        let token = try await attempt(f.base, configuration: config)
        let manifest = try await prepare(f.base, attempt: token)
        let previous = try await f.preferences.configuration(packageName: Self.fooPackage)
        let db = try SQLiteDatabase(path: f.base.path)
        try db.execute("""
            CREATE TRIGGER fail_pref BEFORE UPDATE ON installed_extension_preferences
            BEGIN SELECT RAISE(ABORT,'private fixture'); END;
            """)
        do {
            _ = try await f.preferences.saveConfiguration(snapshot: previous, userValues: [
                .baseURL: .string("https://deployment.invalid"), .adult: .boolean(true)
            ])
            XCTFail("Expected transaction rollback")
        } catch let error as ExtensionPreferencesError {
            XCTAssertEqual(error, .storageUnavailable)
        }
        let unchanged = try await f.preferences.configuration(packageName: Self.fooPackage)
        XCTAssertEqual(unchanged, previous)
        let active = try await f.base.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(active?.revision, token.revision)
        XCTAssertEqual(active?.state, .downloading)
        let cleanup = try await f.base.store.pendingDownloadCleanup()
        XCTAssertTrue(cleanup.isEmpty)
        _ = try await f.base.store.completeDownload(attempt: token, manifestReceipt: manifest)
    }

    func testExactReadmissionRevokesAttemptAndFailedAdmissionRollsBackRevocation() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        let config = try await execution(f)
        let token = try await attempt(f.base, configuration: config)
        let manifest = try await prepare(f.base, attempt: token)
        let previous = try await f.preferences.configuration(packageName: Self.fooPackage)
        let db = try SQLiteDatabase(path: f.base.path)
        try db.execute("""
            CREATE TRIGGER fail_install BEFORE UPDATE ON installed_extension
            BEGIN SELECT RAISE(ABORT,'private fixture'); END;
            """)
        do {
            _ = try await f.admission.admit(apkBytes: f.bytes, extension: f.entry, apkPath: f.apk.path)
            XCTFail("Expected transaction rollback")
        } catch is SQLiteDatabase.SQLiteError {}
        let active = try await f.base.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(active?.revision, token.revision)
        XCTAssertEqual(active?.state, .downloading)
        let cleanup = try await f.base.store.pendingDownloadCleanup()
        XCTAssertTrue(cleanup.isEmpty)
        try db.execute("DROP TRIGGER fail_install")
        _ = try await f.admission.admit(apkBytes: f.bytes, extension: f.entry, apkPath: f.apk.path)
        let repeated = try await f.preferences.configuration(packageName: Self.fooPackage)
        XCTAssertEqual(repeated.revision, previous.revision)
        XCTAssertEqual(repeated.userValues, previous.userValues)
        await expect(.staleAttempt) { _ = try await f.base.store.completeDownload(attempt: token, manifestReceipt: manifest) }
        let stopped = try await f.base.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(stopped?.state, .paused)
    }

    func testOfflineCompletedHiddenChapterSurvivesDisabledThenAbsentSource() async throws {
        let f = try await fooFixture()
        defer { try? FileManager.default.removeItem(at: f.base.folder) }
        let config = try await execution(f)
        let token = try await attempt(f.base, configuration: config)
        let manifest = try await prepare(f.base, attempt: token)
        _ = try await f.base.store.completeDownload(attempt: token, manifestReceipt: manifest)
        try await f.base.store.setExtensionEnabled(false, packageName: Self.fooPackage)
        try await f.base.store.replaceChapters(mangaId: f.base.mangaID, with: [])
        let disabled = try await f.base.store.offlineChapter(chapterID: token.identity.chapterID)
        XCTAssertEqual(disabled?.identity, token.identity)
        XCTAssertFalse(disabled?.isCurrentChapter ?? true)
        XCTAssertEqual(disabled?.chapter.lastPageRead, 7)
        XCTAssertTrue(disabled?.chapter.read ?? false)
        let db = try SQLiteDatabase(path: f.base.path)
        try db.run("DELETE FROM installed_extension WHERE package_name=?", [.text(Self.fooPackage)])
        try FileManager.default.removeItem(at: f.apk)
        let reopened = try LibraryStore(path: f.base.path)
        let absent = try await reopened.offlineChapter(chapterID: token.identity.chapterID)
        XCTAssertEqual(absent, disabled)
        XCTAssertNil(try db.query("SELECT package_name FROM installed_extension").first)
    }

    func testIdenticalFacadeInvalidationDoesNotAffectCompletedBundle() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let complete = try await attempt(f)
        let manifest = try await prepare(f, attempt: complete)
        _ = try await f.store.completeDownload(attempt: complete, manifestReceipt: manifest)
        let active = try await attempt(f, index: 1)
        _ = try await prepare(f, attempt: active)
        let cleanup = try await f.store.invalidateDownloadAttempts(sourceIDs: [Self.nativeID])
        XCTAssertEqual(cleanup, [active.identity])
        let local = try await f.store.offlineChapter(chapterID: complete.identity.chapterID)
        XCTAssertEqual(local?.identity, complete.identity)
        let stopped = try await f.store.downloadItem(jobID: active.jobID)
        XCTAssertEqual(stopped?.state, .paused)
    }

    func testCancelledCallerCannotEnqueueOrCommitPageAndExplicitCancelStillPersists() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let token = try await attempt(f)
        _ = try await f.store.setDownloadPageCount(attempt: token, pageCount: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await f.store.commitDownloadPage(attempt: token, receipt: .init(ordinal: 0, byteCount: 4, sha256: Self.pageHash))
                XCTFail("Cancelled caller cannot commit")
            } catch is CancellationError {}
            _ = try await f.store.cancelDownload(jobID: token.jobID)
        }
        try await task.value
        let item = try await f.store.downloadItem(jobID: token.jobID)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(item?.completedPages, 0)
        XCTAssertEqual(item?.storedBytes, 0)
    }
}
#endif
