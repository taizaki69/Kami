import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class LibraryMutationContextModelTests: XCTestCase {
    func testConstructedLibraryValuesDoNotIssueMutationAuthority() {
        XCTAssertNil(LibrarySnapshot().mutationContext)
        XCTAssertNil(LibrarySnapshot(manga: [.init(id: 1, sourceId: 1, url: "/m")],
                                    categories: [.init(id: 1, name: "Fixture")]).mutationContext)
    }
}

#if canImport(SQLite3)
final class LibraryMutationContextTests: XCTestCase {
    private struct Fixture {
        let folder: URL
        let path: String
        let store: LibraryStore
        let db: SQLiteDatabase
        let manga: Manga
        let first: Int64
        let second: Int64
        let context: LibraryMutationContext
    }

    private func fixture() async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Mutation-Context-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let mangaID = try await store.upsert(Manga(sourceId: MangaDexSource().id, url: "/m",
                                                 title: "Original", inLibrary: true))
        try await store.replaceChapters(mangaId: mangaID, with: [
            .init(mangaId: mangaID, url: "/c", name: "Chapter", read: true, bookmark: true, lastPageRead: 4)])
        let context = try await store.mutationContextForTest()
        let a = try await store.createCategory(name: "A", context: context)
        let b = try await store.createCategory(name: "B", context: context)
        let first = try XCTUnwrap(a.id), second = try XCTUnwrap(b.id)
        try await store.setCategories([first], mangaId: mangaID, context: context)
        let chapters = try await store.chapters(mangaId: mangaID)
        let chapterID = try XCTUnwrap(chapters.first?.id)
        _ = try await store.enqueueDownload(chapterID: chapterID, expectedConfiguration: nil)
        let target = try await readingTargetForTest(store: store, mangaID: mangaID, chapterID: chapterID)
        try await store.commitReadingProgress(target: target, page: 4, reachedEnd: true, lastRead: 123)
        let db = try SQLiteDatabase(path: path)
        try db.run("UPDATE history SET read_duration=19 WHERE chapter_id=?", [.int(chapterID)])
        let stored = try await store.manga(id: mangaID)
        return Fixture(folder: folder, path: path, store: store, db: db, manga: try XCTUnwrap(stored),
                       first: first, second: second, context: context)
    }

    /// Simulates a later committed restore generation. Production still has
    /// no standalone rotation API; this fixture never claims to implement one.
    private func rotate(_ f: Fixture) throws {
        try f.db.execute("UPDATE library_data_state SET epoch=randomblob(16)")
    }

    private func expect(
        _ expected: LibraryMutationError, _ action: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? LibraryMutationError, expected, file: file, line: line) }
    }

    private func categoryActions(
        _ f: Fixture, context: LibraryMutationContext
    ) -> [() async throws -> Void] {
        let id = f.manga.id!
        return [
            { _ = try await f.store.createCategory(name: "Late", context: context) },
            { try await f.store.renameCategory(id: f.first, name: "Late", context: context) },
            { try await f.store.reorderCategories(ids: [f.second, f.first], context: context) },
            { try await f.store.deleteCategories(ids: [f.first], context: context) },
            { try await f.store.setCategories([f.second], mangaId: id, context: context) },
            { try await f.store.setCategories([f.second], mangaIDs: [id], context: context) },
            { try await f.store.updateCategories(adding: [f.second], removing: [f.first], mangaIDs: [id], context: context) },
            { try await f.store.setLibrary(false, mangaId: id, context: context) },
            { try await f.store.deleteCategories(ids: [], context: context) },
            { try await f.store.setCategories([], mangaIDs: [], context: context) },
            { try await f.store.updateCategories(adding: [], removing: [], mangaIDs: [], context: context) },
        ]
    }

    func testStoredSnapshotsPairContextsEvenForEmptyNewSourceManga() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let library = try await f.store.librarySnapshot()
        let reading = try await f.store.readingSnapshot(sourceID: f.manga.sourceId, mangaURL: f.manga.url)
        let detail = try await f.store.sourceMangaSnapshot(sourceID: f.manga.sourceId, mangaURL: f.manga.url)
        let empty = try await f.store.sourceMangaSnapshot(sourceID: f.manga.sourceId, mangaURL: "/new")
        XCTAssertEqual(library.mutationContext, f.context)
        XCTAssertEqual(reading?.mutationContext, f.context)
        XCTAssertEqual(detail.mutationContext, f.context)
        XCTAssertEqual(detail.reading, reading)
        XCTAssertEqual(empty.mutationContext, f.context)
        XCTAssertNil(empty.reading)
        let scan = try await f.store.beginLibraryUpdateScan()
        XCTAssertEqual(scan.mutationContext, f.context)
        _ = try await f.store.finishLibraryUpdateScan(scanID: scan.record.scanID, status: .cancelled)
    }

    func testEveryCategoryAndMembershipWriteRejectsAnOldEpochWithoutAnyEffects() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try rotate(f)
        let before = try await f.store.exportBackupSnapshot(exportedAt: 0)
        let downloads = try await f.store.downloadsSnapshot()
        for action in categoryActions(f, context: f.context) { await expect(.staleEpoch, action) }
        let after = try await f.store.exportBackupSnapshot(exportID: before.exportID, exportedAt: 0)
        let currentDownloads = try await f.store.downloadsSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(currentDownloads, downloads)
    }

    func testReopenedStoreRejectsForeignContextsEvenWithTheSameDurableEpoch() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let other = try LibraryStore(path: f.path)
        let snapshot = try await other.librarySnapshot()
        let context = try XCTUnwrap(snapshot.mutationContext)
        XCTAssertEqual(context.epoch, f.context.epoch)
        XCTAssertNotEqual(context, f.context)
        for action in categoryActions(f, context: context) { await expect(.foreignContext, action) }
        await expect(.foreignContext) {
            _ = try await other.sourceMangaSnapshot(mangaID: f.manga.id!, validating: f.context)
        }
    }

    func testContextSurvivesOrdinaryMetadataReadingAndCategoryChanges() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try await f.store.renameCategory(id: f.first, name: "Renamed", context: f.context)
        try await f.store.reorderCategories(ids: [f.second, f.first], context: f.context)
        try await f.store.updateCategories(adding: [f.second], removing: [], mangaIDs: [f.manga.id!], context: f.context)
        _ = try await f.store.persistSourceUpdate(manga: f.manga, chapters: [.init(url: "/c", name: "Refreshed")],
                                                  expectedConfiguration: nil, context: f.context)
        let snapshot = try await f.store.librarySnapshot()
        XCTAssertEqual(snapshot.mutationContext, f.context)
        XCTAssertEqual(snapshot.categories.map(\.name), ["B", "Renamed"])
        XCTAssertEqual(snapshot.categoryIDsByManga[f.manga.id!], [f.first, f.second])
        let chapters = try await f.store.chapters(mangaId: f.manga.id!)
        XCTAssertEqual(chapters.first?.lastPageRead, 4)
        XCTAssertEqual(chapters.first?.read, true)
        XCTAssertEqual(chapters.first?.bookmark, true)
    }

    func testCorruptOrMissingEpochFailsWithoutRepairOrMutation() async throws {
        for sql in ["DELETE FROM library_data_state",
                    "UPDATE library_data_state SET epoch=zeroblob(1000000)",
                    "UPDATE library_data_state SET epoch='invalid'"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.folder) }
            try f.db.execute("PRAGMA ignore_check_constraints=ON")
            try f.db.execute(sql)
            await expect(.invalidStoredState) {
                try await f.store.renameCategory(id: f.first, name: "Must not save", context: f.context)
            }
            await expect(.invalidStoredState) { _ = try await f.store.librarySnapshot() }
            let categories = try await f.store.categories()
            XCTAssertEqual(categories.map(\.name), ["A", "B"])
            if sql.hasPrefix("DELETE") {
                XCTAssertTrue(try f.db.query("SELECT 1 FROM library_data_state").isEmpty)
            } else {
                XCTAssertNotEqual(try f.db.query("SELECT length(epoch) AS n FROM library_data_state").first?.int("n"), 16)
            }
        }
    }

    func testLateWriteFailureRollsBackAndDoesNotConsumeTheContext() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let before = try await f.store.librarySnapshot()
        try f.db.execute("""
            CREATE TRIGGER reject_category_delete BEFORE DELETE ON category
            WHEN OLD.id=\(f.second) BEGIN SELECT RAISE(ABORT,'injected'); END;
            """)
        await expect(.storageUnavailable) {
            try await f.store.deleteCategories(ids: [f.first, f.second], context: f.context)
        }
        let after = try await f.store.librarySnapshot()
        XCTAssertEqual(after.categories, before.categories)
        XCTAssertEqual(after.categoryIDsByManga, before.categoryIDsByManga)
        XCTAssertEqual(after.mutationContext, f.context)
        try f.db.execute("DROP TRIGGER reject_category_delete")
        try await f.store.deleteCategories(ids: [f.second], context: f.context)
        let retried = try await f.store.categories()
        XCTAssertEqual(retried.map(\.id), [f.first])
    }

    func testSourceChecksAndExistingOrNewResultsRejectCapturedOldContext() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let empty = try await f.store.sourceMangaSnapshot(sourceID: f.manga.sourceId, mangaURL: "/new")
        let before = try await f.store.exportBackupSnapshot(exportedAt: 0)
        try rotate(f)
        await expect(.staleEpoch) {
            try await f.store.validateSourceExecution(sourceID: f.manga.sourceId, expectedConfiguration: nil, context: f.context)
        }
        for manga in [f.manga, Manga(sourceId: f.manga.sourceId, url: "/new", title: "Late")] {
            await expect(.staleEpoch) {
                _ = try await f.store.persistSourceUpdate(manga: manga, chapters: [.init(url: "/late", name: "Late")],
                                                          expectedConfiguration: nil, context: empty.mutationContext)
            }
        }
        await expect(.staleEpoch) {
            _ = try await f.store.sourceMangaSnapshot(sourceID: f.manga.sourceId, mangaURL: f.manga.url,
                                                     validating: f.context)
        }
        await expect(.staleEpoch) {
            _ = try await f.store.sourceMangaSnapshot(mangaID: f.manga.id!, validating: f.context)
        }
        let after = try await f.store.exportBackupSnapshot(exportID: before.exportID, exportedAt: 0)
        XCTAssertEqual(after, before)
    }

    func testManualScanCannotCommitDomainResultsFromAnOldEpoch() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let scan = try await f.store.beginLibraryUpdateScan()
        try rotate(f)
        await expect(.staleEpoch) {
            try await f.store.verifyLibraryUpdateSourceConfiguration(
                sourceID: f.manga.sourceId, expectedConfiguration: nil, context: scan.mutationContext)
        }
        await expect(.staleEpoch) {
            _ = try await f.store.recordLibraryUpdateSuccess(scanID: scan.record.scanID, manga: f.manga,
                chapters: [.init(url: "/late", name: "Late")], expectedConfiguration: nil, context: scan.mutationContext)
        }
        let snapshot = try await f.store.libraryUpdatesSnapshot()
        XCTAssertEqual(snapshot.latestScan?.checked, 0)
        XCTAssertEqual(snapshot.latestScan?.newChapters, 0)
        let chapters = try await f.store.chapters(mangaId: f.manga.id!)
        XCTAssertEqual(chapters.map(\.url), ["/c"])
        _ = try await f.store.finishLibraryUpdateScan(scanID: scan.record.scanID, status: .cancelled)
    }

    private actor Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }

    private struct Source: KamiSource {
        let id = MangaDexSource().id
        let name = "Offline context fixture"
        let language = "en"
        let baseURL = "https://offline.invalid"
        let gate: Gate?
        let counter: Counter
        func getPopularManga(page: Int) async throws -> MangasPageCompat { throw CancellationError() }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat { throw CancellationError() }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { throw CancellationError() }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { throw CancellationError() }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { throw CancellationError() }
        func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
            await counter.increment()
            if let gate { await gate.wait() }
            var changed = manga
            changed.title = "Late provider title"
            return .init(manga: changed, chapters: [.init(url: "/late", name: "Late")])
        }
    }

    func testLibraryServiceRejectsStaleContextBeforeCallingProvider() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try rotate(f)
        let counter = Counter()
        await expect(.staleEpoch) {
            _ = try await LibraryService(store: f.store).refresh(
                mangaId: f.manga.id!, source: Source(gate: nil, counter: counter), context: f.context)
        }
        let count = await counter.count
        XCTAssertEqual(count, 0)
    }

    func testSuspendedProviderCannotPublishAfterEpochChanges() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "Provider suspended")
        let gate = Gate(entered)
        let before = try await f.store.exportBackupSnapshot(exportedAt: 0)
        let task = Task {
            try await LibraryService(store: f.store).refresh(
                mangaId: f.manga.id!, source: Source(gate: gate, counter: Counter()), context: f.context)
        }
        await fulfillment(of: [entered], timeout: 5)
        try rotate(f)
        await gate.release()
        await expect(.staleEpoch) { _ = try await task.value }
        let after = try await f.store.exportBackupSnapshot(exportID: before.exportID, exportedAt: 0)
        XCTAssertEqual(after, before)
    }

    func testQueuedIntentKeepsItsOriginalContextBeforeEnteringStore() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "Intent scheduled")
        let gate = Gate(entered)
        let captured = f.context
        let task = Task {
            await gate.wait()
            try await f.store.setLibrary(false, mangaId: f.manga.id!, context: captured)
        }
        await fulfillment(of: [entered], timeout: 5)
        try rotate(f)
        await gate.release()
        await expect(.staleEpoch) { try await task.value }
        let current = try await f.store.manga(id: f.manga.id!)
        XCTAssertEqual(current?.inLibrary, true)
    }

    func testCancelledQueuedIntentHasNoEffectsWithAValidContext() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "Intent waiting")
        let gate = Gate(entered)
        let task = Task {
            await gate.wait()
            try await f.store.deleteCategories(ids: [f.first], context: f.context)
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("Cancelled intent saved") }
        catch { XCTAssertTrue(error is CancellationError) }
        let categories = try await f.store.categories()
        XCTAssertEqual(categories.map(\.id), [f.first, f.second])
    }

    func testScannerReportsLibraryChangeAndDrainsItsSuspendedProvider() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "Scanner provider suspended")
        let gate = Gate(entered)
        let service = LibraryUpdateService(store: f.store)
        let run = try await service.start(sources: [
            f.manga.sourceId: .available(source: Source(gate: gate, counter: Counter()), expectedConfiguration: nil)])
        let collector = Task { () -> [LibraryUpdateProgress] in
            var values: [LibraryUpdateProgress] = []
            for await value in run.updates { values.append(value) }
            return values
        }
        await fulfillment(of: [entered], timeout: 5)
        try rotate(f)
        await gate.release()
        let values = await collector.value
        XCTAssertEqual(values.last?.phase, .finished)
        XCTAssertEqual(values.last?.error, .libraryChanged)
        XCTAssertEqual(values.last?.summary.status, .cancelled)
        XCTAssertEqual(values.last?.summary.newChapters, 0)
        let current = try await f.store.manga(id: f.manga.id!)
        XCTAssertEqual(current?.title, "Original")
    }
}
#endif
