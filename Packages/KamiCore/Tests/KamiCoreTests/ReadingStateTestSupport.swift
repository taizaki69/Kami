import XCTest
@testable import KamiCore

#if canImport(SQLite3)
/// Fixture setup explicitly opens the stored manga once, before retaining any
/// target. Production retained sessions must never use this to rebase an epoch.
func readingTargetForTest(store: LibraryStore, mangaID: Int64, chapterID: Int64) async throws -> ChapterWriteTarget {
    let saved = try await store.manga(id: mangaID)
    let manga = try XCTUnwrap(saved)
    let result = try await store.readingSnapshot(sourceID: manga.sourceId, mangaURL: manga.url,
                                                requestedChapterID: chapterID)
    return try XCTUnwrap(result?.target(for: chapterID))
}
#endif
