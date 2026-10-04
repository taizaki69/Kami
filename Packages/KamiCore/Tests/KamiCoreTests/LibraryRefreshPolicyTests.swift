import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

#if canImport(SQLite3)
final class LibraryRefreshPolicyTests: XCTestCase {
    private actor ReceivedPolicies {
        private(set) var values: [UpdateStrategy] = []
        func record(_ value: UpdateStrategy) { values.append(value) }
    }

    private struct PolicySource: KamiSource {
        let id = MangaDexSource().id
        let name = "Offline policy fixture"
        let language = "en"
        let baseURL = "https://fixture.invalid"
        let received: ReceivedPolicies

        func getPopularManga(page: Int) async throws -> MangasPageCompat {
            XCTFail("A metadata refresh must not browse")
            return .init(mangas: [], hasNextPage: false)
        }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            XCTFail("A metadata refresh must not search")
            return .init(mangas: [], hasNextPage: false)
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
            await received.record(manga.updateStrategy)
            var result = manga
            result.title = "Complete archive"
            result.updateStrategy = .onlyFetchOnce
            return result
        }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
            [.init(url: "/chapter", name: "Chapter")]
        }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
    }

    func testExplicitMetadataRefreshPersistsAndReusesSourceUpdateStrategy() async throws {
        let store = try LibraryStore(inMemory: true)
        let received = ReceivedPolicies()
        let source = PolicySource(received: received)
        let id = try await store.upsert(Manga(sourceId: source.id, url: "/archive", inLibrary: true))
        let service = LibraryService(store: store)
        let first = try await service.refresh(mangaId: id, source: source)
        XCTAssertEqual(first?.updateStrategy, .onlyFetchOnce)
        // Explicit refresh remains available even when routine scanning will
        // skip this archive after its first successful chapter baseline.
        let second = try await service.refresh(mangaId: id, source: source)
        let policies = await received.values
        XCTAssertEqual(policies, [.alwaysUpdate, .onlyFetchOnce])
        XCTAssertEqual(second?.id, id)
        XCTAssertEqual(second?.updateStrategy, .onlyFetchOnce)
        XCTAssertEqual(second?.inLibrary, true)
    }
}
#endif
