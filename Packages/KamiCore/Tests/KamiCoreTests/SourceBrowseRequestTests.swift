import XCTest
import MihonCompatKit
@testable import KamiCore

final class SourceBrowseRequestTests: XCTestCase {
    func testRoutesFeedsTextSearchAndBlankFilteredSearch() async throws {
        let source = BrowseRoutingSource()
        let filter = SourceFilter.select(
            name: "Genre",
            values: ["All", "Comedy"],
            state: 1
        )

        let popular = try await SourceBrowseRequest(
            page: 2,
            feed: .popular,
            query: "   ",
            filters: [filter]
        ).execute(on: source)
        XCTAssertEqual(popular.mangas.first?.title, "popular:2")

        let latest = try await SourceBrowseRequest(
            page: 3,
            feed: .latest,
            query: "",
            filters: []
        ).execute(on: source)
        XCTAssertEqual(latest.mangas.first?.title, "latest:3")

        let textSearch = try await SourceBrowseRequest(
            page: 4,
            feed: .popular,
            query: "  space opera  ",
            filters: [filter]
        ).execute(on: source)
        XCTAssertEqual(textSearch.mangas.first?.title, "search:4:space opera:1")

        let filteredSearch = try await SourceBrowseRequest(
            page: 5,
            feed: .latest,
            query: "",
            filters: [filter],
            forceSearch: true
        ).execute(on: source)
        XCTAssertEqual(filteredSearch.mangas.first?.title, "search:5::1")
    }
}

private struct BrowseRoutingSource: KamiSource {
    let id: Int64 = 1
    let name = "Routing fixture"
    let language = "en"
    let supportsLatest = true
    let baseURL = "https://example.invalid"

    func getPopularManga(page: Int) async throws -> MangasPageCompat {
        pageResult("popular:\(page)")
    }

    func getLatestUpdates(page: Int) async throws -> MangasPageCompat {
        pageResult("latest:\(page)")
    }

    func getSearchManga(
        page: Int,
        query: String,
        filters: [SourceFilter]
    ) async throws -> MangasPageCompat {
        pageResult("search:\(page):\(query):\(filters.count)")
    }

    func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
        manga
    }

    func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
        []
    }

    func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] {
        []
    }

    private func pageResult(_ title: String) -> MangasPageCompat {
        MangasPageCompat(
            mangas: [SMangaCompat(url: "/\(title)", title: title)],
            hasNextPage: false
        )
    }
}
