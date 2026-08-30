import Foundation
import XCTest
@testable import MihonCompatKit

final class TuttoAnimeMangaInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(String)
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "tutto-anime-manga-adapter-test"

        private let responses: [String: CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []

        init(responses: [String: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard let response = responses[request.url] else {
                throw RoutingError.missingResponse(request.url)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/tuttoanimemanga.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK tuttoanimemanga.apk not present — run scripts/fetch_corpus.sh")
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

    func testCurrentTuttoAnimeMangaProfileExecutesEveryCoreSourceOperation() async throws {
        let listingURL = "https://tuttoanimemanga.net/api/comics"
        let searchURL = "https://tuttoanimemanga.net/api/search/one%20piece%2Fa"
        let detailsURL = "https://tuttoanimemanga.net/api/comics/hero"
        let pagesURL = "https://tuttoanimemanga.net/api/chapters/chapter-7"
        let listingJSON = #"{"server_only":true,"comics":[{"id":1,"title":"Older","thumbnail":"https://images.example/older.jpg","url":"/comics/older","last_chapter":null},{"id":2,"title":"Hero","thumbnail":"https://images.example/hero.jpg","url":"/comics/hero","last_chapter":{"chapter":7,"full_title":"Chapter Seven","published_on":"2026-08-23T12:34:56Z","url":"/chapters/chapter-7","ignored":"value"}}]}"#
        let searchJSON = #"{"server_only":true,"comics":[{"id":2,"title":"Hero","thumbnail":"https://images.example/hero.jpg","url":"/comics/hero"}]}"#
        let detailsJSON = #"{"server_only":true,"comic":{"id":2,"artist":"Artist","author":"Writer","chapters":[{"chapter":7,"subchapter":5,"full_title":"Chapter Seven","published_on":"2026-08-23T12:34:56Z","teams":[{"name":"Team A","id":11},null,{"name":"Team B","id":12}],"url":"/chapters/chapter-7","ignored":"value"}],"description":"A measured hero.","genres":[{"name":"Action","id":21},{"name":"Adventure","id":22}],"status":"In corso","title":"Hero","thumbnail":"https://images.example/hero.jpg","url":"/comics/hero","updated_at":"ignored"}}"#
        let pagesJSON = #"{"server_only":true,"chapter":{"pages":["https://images.example/page-1.jpg","https://images.example/page-2.jpg"],"previous":null,"next":null}}"#
        let transport = RoutingTransport(responses: [
            listingURL: response(url: listingURL, json: listingJSON),
            searchURL: response(url: searchURL, json: searchJSON),
            detailsURL: response(url: detailsURL, json: detailsJSON),
            pagesURL: response(url: pagesURL, json: pagesJSON),
        ])

        let source = try PinnedInterpretedSource.tuttoAnimeManga1610(
            apkBytes: corpusAPK(),
            transport: transport
        )
        XCTAssertEqual(source.id, 2_102_507_871_480_604_746)
        XCTAssertEqual(source.name, "TuttoAnimeManga")
        XCTAssertEqual(source.language, "it")
        XCTAssertEqual(source.baseURL, "https://tuttoanimemanga.net")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertTrue(source.getFilterList().isEmpty)

        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.map(\.title), ["Older", "Hero"])
        XCTAssertEqual(popular.mangas.map(\.url), ["/comics/older", "/comics/hero"])
        XCTAssertFalse(popular.hasNextPage)

        let latest = try await source.getLatestUpdates(page: 2)
        XCTAssertEqual(latest.mangas.map(\.title), ["Hero"])
        XCTAssertFalse(latest.hasNextPage)

        let search = try await source.getSearchManga(
            page: 3,
            query: "one piece/a",
            filters: []
        )
        XCTAssertEqual(search.mangas.map(\.title), ["Hero"])
        XCTAssertFalse(search.hasNextPage)

        let inputManga = SMangaCompat(
            url: "/comics/hero",
            title: "Old title"
        )
        let update = try await source.getMangaUpdate(manga: inputManga)
        XCTAssertEqual(update.manga.url, inputManga.url)
        XCTAssertEqual(update.manga.title, "Hero")
        XCTAssertEqual(update.manga.description, "A measured hero.")
        XCTAssertEqual(update.manga.author, "Writer")
        XCTAssertEqual(update.manga.artist, "Artist")
        XCTAssertEqual(update.manga.genres, ["Action", "Adventure"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.ongoing.rawValue)
        XCTAssertEqual(update.manga.thumbnailURL, "https://images.example/hero.jpg")
        XCTAssertEqual(update.chapters.count, 1)
        XCTAssertEqual(update.chapters[0].url, "/chapters/chapter-7")
        XCTAssertEqual(update.chapters[0].name, "Chapter Seven")
        XCTAssertEqual(update.chapters[0].chapterNumber, 7.5)
        XCTAssertEqual(update.chapters[0].scanlators, ["Team A & Team B"])
        XCTAssertGreaterThan(update.chapters[0].dateUpload, 0)

        let details = try await source.getMangaDetails(manga: inputManga)
        XCTAssertEqual(details.url, inputManga.url)
        XCTAssertEqual(details.title, "Hero")
        let chapters = try await source.getChapterList(manga: inputManga)
        XCTAssertEqual(chapters.map(\.url), ["/chapters/chapter-7"])

        let pages = try await source.getPageList(chapter: update.chapters[0])
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://images.example/page-1.jpg",
            "https://images.example/page-2.jpg",
        ])
        let imageRequest = await source.getImageRequest(page: pages[0])
        XCTAssertEqual(imageRequest?.url, "https://images.example/page-1.jpg")
        XCTAssertEqual(imageRequest?.headers, [
            "Referer": "https://tuttoanimemanga.net/",
            "Origin": "https://tuttoanimemanga.net",
        ])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            listingURL,
            listingURL,
            searchURL,
            detailsURL,
            detailsURL,
            detailsURL,
            pagesURL,
        ])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.body == nil })
        XCTAssertTrue(requests.allSatisfy {
            $0.headers == [
                CompatHTTPHeader(name: "Referer", value: "https://tuttoanimemanga.net/"),
                CompatHTTPHeader(name: "Origin", value: "https://tuttoanimemanga.net"),
            ]
        })
        XCTAssertTrue(requests.allSatisfy {
            $0.cachePolicy == CompatHTTPCachePolicy(maxAgeSeconds: 600)
        })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testTuttoRejectsPreferencesAndFiltersBeforeTransport() async throws {
        let bytes = try corpusAPK()
        let transport = RoutingTransport(responses: [:])
        let unsupportedPreferences = try InterpretedExtensionPreferences(
            strings: ["unexpected": "value"]
        )
        XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.it.tuttoanimemanga",
            versionName: "1.6.10",
            versionCode: 10,
            apkBytes: bytes,
            transport: transport,
            preferences: unsupportedPreferences
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .invalidPreferences(profile: "tutto-anime-manga-1.6.10")
            )
        }

        let sources = try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.it.tuttoanimemanga",
            versionName: "1.6.10",
            versionCode: 10,
            apkBytes: bytes,
            transport: transport
        )
        let source = try XCTUnwrap(sources.first)
        do {
            _ = try await source.getSearchManga(
                page: 1,
                query: "hero",
                filters: [.text(name: "unsupported", state: "value")]
            )
            XCTFail("expected Tutto to reject a filter schema it does not expose")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .unsupportedOperation("filtered search"))
        }
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testTuttoLatestSortsPublishTimestampsAndLimitsResultsToTen() async throws {
        let listingURL = "https://tuttoanimemanga.net/api/comics"
        var comics: [[String: Any]] = (1...12).map { index in
            [
                "title": "Series \(index)",
                "thumbnail": "https://images.example/series-\(index).jpg",
                "url": "/comics/series-\(index)",
                "last_chapter": [
                    "chapter": index,
                    "full_title": "Chapter \(index)",
                    "published_on": String(format: "2026-08-%02dT00:00:00Z", index),
                    "url": "/chapters/series-\(index)",
                ],
            ]
        }
        comics.append([
            "title": "No chapter",
            "thumbnail": "https://images.example/no-chapter.jpg",
            "url": "/comics/no-chapter",
            "last_chapter": NSNull(),
        ])
        let data = try JSONSerialization.data(withJSONObject: ["comics": comics])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let transport = RoutingTransport(responses: [
            listingURL: response(url: listingURL, json: json),
        ])
        let source = try PinnedInterpretedSource.tuttoAnimeManga1610(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let latest = try await source.getLatestUpdates(page: 99)
        XCTAssertEqual(latest.mangas.map(\.title), (3...12).reversed().map {
            "Series \($0)"
        })
        XCTAssertFalse(latest.hasNextPage)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [listingURL])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
}
