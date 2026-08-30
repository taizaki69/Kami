import Foundation
import XCTest
@testable import MihonCompatKit

final class KawiiMangaInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(String)
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "kawii-manga-adapter-test"

        private let responses: [String: CompatHTTPResponse]
        private var recordedRequests: [CompatHTTPRequest] = []

        init(responses: [String: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            recordedRequests.append(request)
            guard let response = responses[request.url] else {
                throw RoutingError.missingResponse(request.url)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] {
            recordedRequests
        }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/kawiimanga.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK kawiimanga.apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func response(url: String, json: String) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(
                name: "Content-Type",
                value: "application/json; charset=utf-8"
            )],
            body: Array(json.utf8)
        )
    }

    func testCurrentKawiiMangaProfileExecutesEveryCoreSourceOperation() async throws {
        let popularURL = "https://manga-api.kawaii-anime.com/api/manga/own?action=browse&page=1&sort=views"
        let latestURL = "https://manga-api.kawaii-anime.com/api/manga/own?action=browse&page=2"
        let searchURL = "https://manga-api.kawaii-anime.com/api/manga/own?action=search&q=hero"
        let detailsURL = "https://manga-api.kawaii-anime.com/api/manga/own?action=series&slug=hero"
        let pagesURL = "https://manga-api.kawaii-anime.com/api/manga/own?action=pages&chapterId=chapter-7"
        let listingJSON = #"{"results":[{"slug":"hero","title":"Hero","description":null,"coverUrl":"https://images.example/hero.jpg","author":"Writer","artist":"Artist","type":"manga","status":"ongoing","genres":["Action"]}],"hasMore":true}"#
        let detailsJSON = #"{"slug":"hero","title":"Hero","description":"A measured hero.","coverUrl":"https://images.example/hero.jpg","author":"Writer","artist":"Artist","type":"manga","status":"ongoing","genres":["Action"],"chapters":[{"id":"chapter-7","title":"Chapter Seven","number":7,"createdAt":"2026-08-23T12:34:56Z"}]}"#
        let pagesJSON = #"{"pages":["https://images.example/page-1.jpg","https://images.example/page-2.jpg"]}"#
        let transport = RoutingTransport(responses: [
            popularURL: response(url: popularURL, json: listingJSON),
            latestURL: response(url: latestURL, json: listingJSON),
            searchURL: response(url: searchURL, json: listingJSON),
            detailsURL: response(url: detailsURL, json: detailsJSON),
            pagesURL: response(url: pagesURL, json: pagesJSON),
        ])

        let source = try PinnedInterpretedSource.kawiiManga161(
            apkBytes: corpusAPK(),
            transport: transport
        )
        XCTAssertEqual(source.id, 5_037_404_094_705_788_694)
        XCTAssertEqual(source.name, "Kawii Manga")
        XCTAssertEqual(source.language, "ar")
        XCTAssertEqual(source.baseURL, "https://kawaiimanga.org")
        XCTAssertTrue(source.supportsLatest)

        let popular: MangasPageCompat
        do {
            popular = try await source.getPopularManga(page: 1)
        } catch {
            XCTFail("popular manga failed: \(error)")
            throw error
        }
        XCTAssertEqual(popular.mangas.first?.url, "hero")
        XCTAssertEqual(popular.mangas.first?.title, "Hero")
        XCTAssertTrue(popular.hasNextPage)

        let latest: MangasPageCompat
        do {
            latest = try await source.getLatestUpdates(page: 2)
        } catch {
            XCTFail("latest updates failed: \(error)")
            throw error
        }
        XCTAssertEqual(latest.mangas.first?.title, "Hero")

        let search: MangasPageCompat
        do {
            search = try await source.getSearchManga(page: 3, query: "hero", filters: [])
        } catch {
            XCTFail("search failed: \(error)")
            throw error
        }
        XCTAssertEqual(search.mangas.first?.url, "hero")

        let input = SMangaCompat(url: "hero", title: "Old title")
        let update: SMangaUpdateCompat
        do {
            update = try await source.getMangaUpdate(manga: input)
        } catch {
            XCTFail("manga update failed: \(error)")
            throw error
        }
        XCTAssertEqual(update.manga.title, "Hero")
        XCTAssertEqual(update.manga.description, "A measured hero.")
        XCTAssertEqual(update.manga.author, "Writer")
        XCTAssertEqual(update.manga.artist, "Artist")
        XCTAssertEqual(update.manga.genres, ["Manga", "Action"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.ongoing.rawValue)
        XCTAssertEqual(update.chapters.count, 1)
        XCTAssertEqual(update.chapters[0].url, "hero/7#chapter-7")
        XCTAssertEqual(update.chapters[0].name, "الفصل 7 - Chapter Seven")
        XCTAssertEqual(update.chapters[0].chapterNumber, -1)

        let pages: [PageCompat]
        do {
            pages = try await source.getPageList(chapter: update.chapters[0])
        } catch {
            XCTFail("page list failed: \(error)")
            throw error
        }
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://images.example/page-1.jpg",
            "https://images.example/page-2.jpg",
        ])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            popularURL,
            latestURL,
            searchURL,
            detailsURL,
            pagesURL,
        ])
        for request in requests {
            XCTAssertTrue(request.headers.contains {
                $0.name.lowercased() == "x-app-key" && $0.value == "km_2026_live"
            })
        }
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
}
