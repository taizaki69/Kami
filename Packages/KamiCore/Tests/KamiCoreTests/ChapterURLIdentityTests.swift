import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

private let composedChapterURL = "/chapter/caf\u{00e9}"
private let decomposedChapterURL = "/chapter/cafe\u{0301}"

final class ChapterURLIdentityModelTests: XCTestCase {
    func testDiscoveryIdentityAndCursorDistinguishURLBytes() {
        XCTAssertEqual(composedChapterURL, decomposedChapterURL, "Swift text equality is not URL identity")
        XCTAssertNotEqual(Data(composedChapterURL.utf8), Data(decomposedChapterURL.utf8))
        let manga = Manga(id: 7, sourceId: 1, url: "/manga", title: "Fixture")
        let a = LibraryChapterDiscovery(manga: manga,
            chapter: Chapter(id: 11, mangaId: 7, url: composedChapterURL, name: "A"), detectedAt: 123)
        let b = LibraryChapterDiscovery(manga: manga,
            chapter: Chapter(id: 12, mangaId: 7, url: decomposedChapterURL, name: "B"), detectedAt: 123)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(Set([a.id, b.id]).count, 2, "Updates must retain both rows")
        let renamed = LibraryChapterDiscovery(manga: manga,
            chapter: Chapter(id: 99, mangaId: 7, url: composedChapterURL, name: "Renamed"), detectedAt: 456)
        XCTAssertEqual(a.id, renamed.id, "The durable discovery key is manga and exact URL")
        let otherManga = LibraryChapterDiscovery(manga: manga,
            chapter: Chapter(id: 11, mangaId: 8, url: composedChapterURL, name: "A"), detectedAt: 123)
        XCTAssertNotEqual(a.id, otherManga.id)
        let cursor = LibraryChapterDiscoveryCursor(detectedAt: 123, mangaID: 7, chapterURL: composedChapterURL)
        XCTAssertNotEqual(cursor,
            LibraryChapterDiscoveryCursor(detectedAt: 123, mangaID: 7, chapterURL: decomposedChapterURL))
        XCTAssertEqual(cursor,
            LibraryChapterDiscoveryCursor(detectedAt: 123, mangaID: 7, chapterURL: composedChapterURL))
    }
}

#if canImport(SQLite3)
final class ChapterURLIdentityPersistenceTests: XCTestCase {
    private func addManga(to store: LibraryStore) async throws -> Manga {
        let id = try await store.upsert(Manga(
            sourceId: MangaDexSource().id, url: "/fixture", title: "Fixture", inLibrary: true))
        let value = try await store.manga(id: id)
        return try XCTUnwrap(value)
    }

    private func sourceChapters() -> [SChapterCompat] {
        [.init(url: composedChapterURL, name: "A"),
         .init(url: decomposedChapterURL, name: "B"),
         .init(url: composedChapterURL, name: "Duplicate A"),
         .init(url: decomposedChapterURL, name: "Duplicate B")]
    }

    func testReplacementInsertsBothSpellingsAndKeepsFirstExactDuplicate() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await addManga(to: store)
        let id = try XCTUnwrap(manga.id)
        try await store.replaceChapters(mangaId: id, with: sourceChapters().enumerated().map {
            Chapter(mangaId: id, sourceOrder: $0.offset, from: $0.element)
        })
        let chapters = try await store.chapters(mangaId: id)
        XCTAssertEqual(chapters.map { Data($0.url.utf8) },
                       [Data(composedChapterURL.utf8), Data(decomposedChapterURL.utf8)])
        XCTAssertEqual(chapters.map(\.name), ["A", "B"])
        XCTAssertEqual(chapters.map(\.sourceOrder), [0, 1])
        XCTAssertEqual(Set(chapters.compactMap(\.id)).count, 2)
        let document = try await store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(document.manga.first?.knownChapters.count, 2)
    }

    func testRefreshRetainsExistingRowStateHistoryAndOnlyPausesMissingExactChapter() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Chapter-Identity-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let manga = try await addManga(to: store)
        let mangaID = try XCTUnwrap(manga.id)
        let db = try SQLiteDatabase(path: path)
        // SQLite already permits both exact keys. Seed that existing state to
        // exercise lookup and disappearance independently of insertion logic.
        let a = try db.insert("""
            INSERT INTO chapter(manga_id,url,name,source_order,bookmark) VALUES (?,?,'A',0,1)
            """, [.int(mangaID), .text(composedChapterURL)])
        let b = try db.insert("""
            INSERT INTO chapter(manga_id,url,name,source_order) VALUES (?,?,'B',1)
            """, [.int(mangaID), .text(decomposedChapterURL)])
        let targetA = try await readingTargetForTest(store: store, mangaID: mangaID, chapterID: a)
        let targetB = try await readingTargetForTest(store: store, mangaID: mangaID, chapterID: b)
        try await store.commitReadingProgress(target: targetA, page: 3, reachedEnd: true, lastRead: 123)
        try await store.commitReadingProgress(target: targetB, page: 8, reachedEnd: false, lastRead: 456)
        try db.run("UPDATE history SET read_duration=17 WHERE chapter_id=?", [.int(a)])
        try db.run("UPDATE history SET read_duration=29 WHERE chapter_id=?", [.int(b)])
        let downloadA = try await store.enqueueDownload(chapterID: a, expectedConfiguration: nil)
        let downloadB = try await store.enqueueDownload(chapterID: b, expectedConfiguration: nil)

        try await store.replaceChapters(mangaId: mangaID, with: [
            Chapter(mangaId: mangaID, url: decomposedChapterURL, name: "B refreshed")])
        let visible = try await store.chapters(mangaId: mangaID)
        XCTAssertEqual(visible.map(\.id), [b])
        XCTAssertEqual(visible.first?.name, "B refreshed")
        let stopped = try await store.downloadItem(jobID: downloadA.jobID)
        let queued = try await store.downloadItem(jobID: downloadB.jobID)
        XCTAssertEqual(stopped?.state, .paused)
        XCTAssertEqual(stopped?.reason, .chapterUnavailable)
        XCTAssertEqual(queued?.state, .queued)
        XCTAssertNil(queued?.reason)
        let history = try await store.history()
        XCTAssertEqual(Set(history.compactMap { $0.1.id }), Set([a, b]))
        let hiddenDocument = try await store.exportBackupSnapshot(exportedAt: 0)
        let hidden = try XCTUnwrap(hiddenDocument.manga.first)
        XCTAssertEqual(hidden.chapters.first { Data($0.url.utf8) == Data(composedChapterURL.utf8) }?.isCurrent, false)
        XCTAssertEqual(hidden.history.first { Data($0.chapterURL.utf8) == Data(composedChapterURL.utf8) }?.readDuration, 17)
        XCTAssertEqual(hidden.history.first { Data($0.chapterURL.utf8) == Data(decomposedChapterURL.utf8) }?.readDuration, 29)

        let reopened = try LibraryStore(path: path)
        try await reopened.replaceChapters(mangaId: mangaID, with: [
            Chapter(mangaId: mangaID, url: decomposedChapterURL, name: "B returned"),
            Chapter(mangaId: mangaID, url: composedChapterURL, name: "A returned")])
        let returned = try await reopened.chapters(mangaId: mangaID)
        XCTAssertEqual(returned.map(\.id), [b, a])
        XCTAssertEqual(returned.map(\.lastPageRead), [8, 3])
        XCTAssertEqual(returned.map(\.read), [false, true])
        XCTAssertEqual(returned.map(\.bookmark), [false, true])
        XCTAssertEqual(returned.map(\.name), ["B returned", "A returned"])
        // A retained reading target still names the same exact physical row.
        try await store.commitReadingProgress(target: targetA, page: 4, reachedEnd: false, lastRead: 789)
        let after = try await reopened.chapters(mangaId: mangaID)
        XCTAssertEqual(after.map(\.lastPageRead), [8, 4])
    }

    func testDetailRefreshAnnouncesNewSpellingWithoutRediscoveringKnownExactURL() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await addManga(to: store)
        _ = try await store.persistSourceUpdate(manga: manga,
            chapters: [.init(url: composedChapterURL, name: "A")], expectedConfiguration: nil)
        let initial = try await store.libraryUpdatesSnapshot()
        XCTAssertTrue(initial.discoveries.isEmpty)
        let result = try await store.persistSourceUpdate(
            manga: manga, chapters: sourceChapters(), expectedConfiguration: nil)
        XCTAssertEqual(result.chapters.map(\.name), ["A", "B"])
        let updates = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(updates.discoveries.map { Data($0.chapter.url.utf8) }, [Data(decomposedChapterURL.utf8)])
        _ = try await store.persistSourceUpdate(
            manga: manga, chapters: sourceChapters(), expectedConfiguration: nil)
        let repeated = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(repeated.discoveries, updates.discoveries)
        let document = try await store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(document.manga.first?.knownChapters.count, 2)
    }

    func testManualScanCountsAndPaginatesBothExactDiscoveriesOnlyOnce() async throws {
        let store = try LibraryStore(inMemory: true)
        let manga = try await addManga(to: store)
        try await store.replaceChapters(mangaId: try XCTUnwrap(manga.id), with: [])
        let start = try await store.beginLibraryUpdateScan()
        let result = try await store.recordLibraryUpdateSuccess(scanID: start.record.scanID,
            manga: manga, chapters: sourceChapters(), expectedConfiguration: nil)
        XCTAssertEqual(result.outcome, .updated(newChapters: 2, establishedBaseline: false))
        let done = try await store.finishLibraryUpdateScan(scanID: start.record.scanID, status: .completed)
        XCTAssertEqual(done.newChapters, 2)
        let first = try await store.libraryUpdatesSnapshot(discoveryLimit: 1)
        XCTAssertTrue(first.hasMore)
        let second = try await store.libraryUpdatesSnapshot(discoveryLimit: 1, after: try XCTUnwrap(first.nextCursor))
        XCTAssertFalse(second.hasMore)
        let discoveries = first.discoveries + second.discoveries
        XCTAssertEqual(Set(discoveries.map { Data($0.chapter.url.utf8) }),
                       Set([Data(composedChapterURL.utf8), Data(decomposedChapterURL.utf8)]))
        XCTAssertEqual(Set(discoveries.map(\.id)).count, 2)
        let again = try await store.beginLibraryUpdateScan()
        let repeated = try await store.recordLibraryUpdateSuccess(scanID: again.record.scanID,
            manga: manga, chapters: sourceChapters(), expectedConfiguration: nil)
        XCTAssertEqual(repeated.outcome, .updated(newChapters: 0, establishedBaseline: false))
        _ = try await store.finishLibraryUpdateScan(scanID: again.record.scanID, status: .completed)
        let current = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(current.discoveries.map(\.id), discoveries.map(\.id))
    }
}
#endif
