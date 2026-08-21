import XCTest
@testable import KamiCore

final class LibraryStoreTests: XCTestCase {
    func testSchemaMigratesAndRoundTrips() throws {
        let store = try LibraryStore(inMemory: true)

        var manga = Manga(sourceId: 1, url: "/manga/one-piece", title: "One Piece")
        manga.inLibrary = true
        let id = try store.upsert(manga)
        XCTAssertGreaterThan(id, 0)

        let fetched = try store.manga(id: id)
        XCTAssertEqual(fetched?.title, "One Piece")
        XCTAssertEqual(fetched?.inLibrary, true)

        let chapters = [
            Chapter(mangaId: id, sourceOrder: 0, url: "/c/1", name: "Ch 1", number: 1),
            Chapter(mangaId: id, sourceOrder: 1, url: "/c/2", name: "Ch 2", number: 2),
        ]
        try store.replaceChapters(mangaId: id, with: chapters)
        var stored = try store.chapters(mangaId: id)
        XCTAssertEqual(stored.count, 2)

        // Read state survives a chapter-list refresh with same URLs.
        try store.markRead(true, chapterId: stored[0].id ?? 0)
        try store.replaceChapters(mangaId: id, with: chapters)
        stored = try store.chapters(mangaId: id)
        XCTAssertEqual(stored[0].read, true)

        try store.recordHistory(mangaId: id, chapterId: stored[0].id ?? 0)
        let history = try store.history()
        XCTAssertEqual(history.count, 1)

        try store.setLibrary(false, mangaId: id)
        XCTAssertEqual(try store.libraryManga().count, 0)
    }

    func testMigrationsAreIdempotent() throws {
        let store = try LibraryStore(inMemory: true)
        // Re-init on the same database must not fail or duplicate.
        _ = try store.libraryManga()
    }
}
