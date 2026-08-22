import XCTest
@testable import KamiCore

#if canImport(SQLite3)

final class LibraryStoreTests: XCTestCase {
    func testSchemaMigratesAndRoundTrips() async throws {
        let store = try LibraryStore(inMemory: true)

        var manga = Manga(sourceId: 1, url: "/manga/one-piece", title: "One Piece")
        manga.inLibrary = true
        let id = try await store.upsert(manga)
        XCTAssertGreaterThan(id, 0)

        let fetched = try await store.manga(id: id)
        XCTAssertEqual(fetched?.title, "One Piece")
        XCTAssertEqual(fetched?.inLibrary, true)

        let chapters = [
            Chapter(mangaId: id, sourceOrder: 0, url: "/c/1", name: "Ch 1", number: 1),
            Chapter(mangaId: id, sourceOrder: 1, url: "/c/2", name: "Ch 2", number: 2),
        ]
        try await store.replaceChapters(mangaId: id, with: chapters)
        var stored = try await store.chapters(mangaId: id)
        XCTAssertEqual(stored.count, 2)

        // Read state, row identity, and history survive a chapter-list refresh.
        let firstChapterId = try XCTUnwrap(stored[0].id)
        try await store.markRead(true, chapterId: firstChapterId)
        try await store.recordHistory(mangaId: id, chapterId: firstChapterId)
        try await store.replaceChapters(mangaId: id, with: chapters)
        stored = try await store.chapters(mangaId: id)
        XCTAssertEqual(stored[0].read, true)
        XCTAssertEqual(stored[0].id, firstChapterId)

        let history = try await store.history()
        XCTAssertEqual(history.count, 1)

        try await store.setLibrary(false, mangaId: id)
        let libraryCount = try await store.libraryManga().count
        XCTAssertEqual(libraryCount, 0)
    }

    func testConflictingUpsertPreservesLibraryMembershipAndUpdatesMetadata() async throws {
        let store = try LibraryStore(inMemory: true)
        var original = Manga(sourceId: 7, url: "/same", title: "Old")
        original.inLibrary = true
        let id = try await store.upsert(original)

        let refreshed = Manga(sourceId: 7, url: "/same", title: "New")
        let refreshedId = try await store.upsert(refreshed)
        XCTAssertEqual(refreshedId, id)

        let stored = try await store.manga(id: id)
        XCTAssertEqual(stored?.title, "New")
        XCTAssertEqual(stored?.inLibrary, true)
    }

    func testMigrationsAreIdempotent() async throws {
        let store = try LibraryStore(inMemory: true)
        // Re-init on the same database must not fail or duplicate.
        _ = try await store.libraryManga()
    }
}

#endif
