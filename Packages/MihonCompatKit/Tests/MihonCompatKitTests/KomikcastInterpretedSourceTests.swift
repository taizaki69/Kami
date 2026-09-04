import Foundation
import XCTest
@testable import MihonCompatKit

final class KomikcastInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(method: String, url: String)
    }

    private struct RouteKey: Hashable, Sendable {
        let method: String
        let url: String
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "komikcast-voratoon-routing-test"
        private let responses: [RouteKey: CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []

        init(responses: [RouteKey: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            let key = RouteKey(method: request.method, url: request.url)
            guard let response = responses[key] else {
                throw RoutingError.missingResponse(method: request.method, url: request.url)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private actor SequencedGenreTransport: CompatHTTPTransport {
        nonisolated let sourceID = "komikcast-voratoon-sequenced-test"
        private let genresURL: String
        private let responses: [CompatHTTPResponse]
        private let additionalResponses: [RouteKey: CompatHTTPResponse]
        private let delayNanoseconds: UInt64
        private var nextResponseIndex = 0
        private var requests: [CompatHTTPRequest] = []
        private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            genresURL: String,
            responses: [CompatHTTPResponse],
            additionalResponses: [RouteKey: CompatHTTPResponse] = [:],
            delayNanoseconds: UInt64 = 0
        ) {
            precondition(!responses.isEmpty)
            self.genresURL = genresURL
            self.responses = responses
            self.additionalResponses = additionalResponses
            self.delayNanoseconds = delayNanoseconds
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }

            let key = RouteKey(method: request.method, url: request.url)
            if let response = additionalResponses[key] {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                return response
            }
            guard request.method == "GET", request.url == genresURL else {
                throw RoutingError.missingResponse(method: request.method, url: request.url)
            }
            let response = responses[min(nextResponseIndex, responses.count - 1)]
            nextResponseIndex += 1
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }

        func waitForFirstRequest() async {
            guard requests.isEmpty else { return }
            await withCheckedContinuation { continuation in
                if requests.isEmpty {
                    firstRequestWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/komikcast.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip(
                "corpus APK komikcast.apk not present — run scripts/fetch_corpus.sh"
            )
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func response(url: String, body: String) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(
                name: "Content-Type",
                value: "application/json; charset=utf-8"
            )],
            body: Array(body.utf8)
        )
    }

    private func response(
        url: String,
        statusCode: Int,
        body: String
    ) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: statusCode,
            headers: [CompatHTTPHeader(
                name: "Content-Type",
                value: "application/json; charset=utf-8"
            )],
            body: Array(body.utf8)
        )
    }

    func testCurrentKomikcastProfileConstructsAndExecutesPopular() async throws {
        let popularURL = "https://api.voratoon.com/series?includeMeta=true&take=12&page=2&sort=totalViews&sortOrder=desc"
        let body = #"{"data":[{"id":42,"data":{"slug":"demo","title":"Demo","author":"Writer","status":"ongoing","synopsis":"Synopsis","coverImage":"https://cdn.example/demo.jpg","genres":[{"data":{"name":"Action"}},{"data":{"name":"Fantasy"}}]}}],"meta":{"page":2,"lastPage":3}}"#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: popularURL): response(url: popularURL, body: body),
        ])
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        XCTAssertEqual(source.id, 972_717_448_578_983_812)
        XCTAssertEqual(source.name, "VoraToon")
        XCTAssertEqual(source.language, "id")
        XCTAssertEqual(source.baseURL, "https://v1.voratoon.com")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertTrue(source.supportsFilterFetching)

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 7)
        XCTAssertEqual(filters.map(\.name), [
            "Sort", "Sort Order", "Status", "Format", "Type", "", "Tap 'Reset' to load filters",
        ])

        let result = try await source.getPopularManga(page: 2)
        XCTAssertEqual(result.mangas.count, 1)
        XCTAssertEqual(result.mangas[0].url, "/series/demo")
        XCTAssertEqual(result.mangas[0].title, "Demo")
        XCTAssertEqual(result.mangas[0].author, "Writer")
        XCTAssertEqual(result.mangas[0].description, "Synopsis")
        XCTAssertEqual(result.mangas[0].genres, ["Action", "Fantasy"])
        XCTAssertEqual(result.mangas[0].status.rawValue, MangaStatus.ongoing.rawValue)
        XCTAssertTrue(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [popularURL])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentKomikcastProfileExecutesLatestSearchDetailsChaptersPagesAndImage() async throws {
        let latestURL = "https://api.voratoon.com/series?includeMeta=true&take=12&page=4&sort=latest&sortOrder=desc"
        let searchURL = "https://api.voratoon.com/series?includeMeta=true&take=12&page=3&title=hero&sort=totalViews&sortOrder=desc"
        let detailsURL = "https://api.voratoon.com/series/demo"
        let chaptersURL = "https://api.voratoon.com/series/demo/chapters"
        let pagesURL = "https://api.voratoon.com/series/demo/chapters/1.5"
        let listBody = #"{"data":[{"id":42,"data":{"slug":"demo","title":"Demo","author":"Writer","status":"completed","synopsis":"Synopsis","coverImage":"https://cdn.example/demo.jpg","genres":[{"data":{"name":"Action"}}]}}],"meta":{"page":4,"lastPage":4}}"#
        let detailBody = #"{"data":{"id":42,"data":{"slug":"demo","title":"Detailed Demo","author":"Detail Writer","status":"hiatus","synopsis":"Detailed synopsis","coverImage":"https://cdn.example/detail.jpg","genres":[{"data":{"name":"Fantasy"}}]}}}"#
        let chapterItem = #"{"data":{"index":1.5,"title":"Side","images":["https://cdn.example/demo/1.jpg","https://cdn.example/demo/2.jpg"]},"createdAt":"2026-01-02T03:04:05Z","updatedAt":null,"chapterIndex":null}"#
        let chaptersBody = #"{"data":["# + chapterItem + #"]}"#
        let pagesBody = #"{"data":"# + chapterItem + #"}"#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: latestURL): response(url: latestURL, body: listBody),
            RouteKey(method: "GET", url: searchURL): response(url: searchURL, body: listBody),
            RouteKey(method: "GET", url: detailsURL): response(url: detailsURL, body: detailBody),
            RouteKey(method: "GET", url: chaptersURL): response(url: chaptersURL, body: chaptersBody),
            RouteKey(method: "GET", url: pagesURL): response(url: pagesURL, body: pagesBody),
        ])
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let latest = try await source.getLatestUpdates(page: 4)
        XCTAssertEqual(latest.mangas.map(\.title), ["Demo"])
        XCTAssertFalse(latest.hasNextPage)

        let search = try await source.getSearchManga(
            page: 3,
            query: "hero",
            filters: source.getFilterList()
        )
        XCTAssertEqual(search.mangas.map(\.url), ["/series/demo"])

        let input = SMangaCompat(url: "/series/demo", title: "Old title")
        let update = try await source.getMangaUpdate(manga: input)
        XCTAssertEqual(update.manga.url, "/series/demo")
        XCTAssertEqual(update.manga.title, "Detailed Demo")
        XCTAssertEqual(update.manga.author, "Detail Writer")
        XCTAssertEqual(update.manga.description, "Detailed synopsis")
        XCTAssertEqual(update.manga.genres, ["Fantasy"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.onHiatus.rawValue)
        XCTAssertEqual(update.chapters.count, 1)
        XCTAssertEqual(update.chapters[0].url, "/series/demo/chapter/1.5")
        XCTAssertEqual(update.chapters[0].name, "Chapter 1.5: Side")
        XCTAssertEqual(update.chapters[0].chapterNumber, 1.5)
        XCTAssertEqual(update.chapters[0].dateUpload, 1_767_323_045_000)

        let pages = try await source.getPageList(chapter: update.chapters[0])
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.url), ["", ""])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://cdn.example/demo/1.jpg",
            "https://cdn.example/demo/2.jpg",
        ])

        let generatedImageRequest = await source.getImageRequest(page: pages[0])
        let imageRequest = try XCTUnwrap(generatedImageRequest)
        XCTAssertEqual(imageRequest.url, "https://cdn.example/demo/1.jpg")
        XCTAssertEqual(imageRequest.headers, [
            "Referer": "https://v1.voratoon.com/",
            "Origin": "https://v1.voratoon.com",
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            "Accept-language": "en-US,en;q=0.9,id;q=0.8",
        ])
        XCTAssertNil(imageRequest.sourceExecutionID)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            latestURL,
            searchURL,
            detailsURL,
            chaptersURL,
            pagesURL,
        ])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        XCTAssertTrue(requests.allSatisfy {
            $0.cachePolicy == CompatHTTPCachePolicy(maxAgeSeconds: 600)
        })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentKomikcastProfileResolvesAnExactSourceSeriesURLSearch() async throws {
        let detailsURL = "https://api.voratoon.com/series/demo"
        let detailBody = #"{"data":{"id":42,"data":{"slug":"demo","title":"URL Demo","author":"Writer","status":"ongoing","synopsis":"Synopsis","coverImage":"https://cdn.example/demo.jpg","genres":[]}}}"#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: detailsURL): response(url: detailsURL, body: detailBody),
        ])
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getSearchManga(
            page: 1,
            query: "https://v1.voratoon.com/series/demo",
            filters: []
        )

        XCTAssertEqual(result.mangas.map(\.url), ["/series/demo"])
        XCTAssertEqual(result.mangas.map(\.title), ["URL Demo"])
        XCTAssertFalse(result.hasNextPage)
        let missingSlug = try await source.getSearchManga(
            page: 1,
            query: "https://v1.voratoon.com/series",
            filters: []
        )
        XCTAssertTrue(missingSlug.mangas.isEmpty)
        XCTAssertFalse(missingSlug.hasNextPage)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [detailsURL])
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentKomikcastProfileRefreshesAndAppliesDynamicGenres() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let searchURL = "https://api.voratoon.com/series?includeMeta=true&take=12&page=3&title=hero&filter=genreIds%3D%3D7%3BgenreIds%3D%3D9&sort=totalViews&sortOrder=desc"
        let genresBody = #"{"data":[{"id":7,"data":{"name":"Action"}},{"id":9,"data":{"name":"Fantasy"}}]}"#
        let listBody = #"{"data":[{"id":42,"data":{"slug":"demo","title":"Demo"}}],"meta":{"page":3,"lastPage":3}}"#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: genresURL): response(url: genresURL, body: genresBody),
            RouteKey(method: "GET", url: searchURL): response(url: searchURL, body: listBody),
        ])
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let initial = source.getFilterList()
        XCTAssertEqual(initial.last?.name, "Tap 'Reset' to load filters")

        var refreshed = try await source.refreshFilterList()
        XCTAssertEqual(refreshed.map(\.name), [
            "Sort", "Sort Order", "Status", "Format", "Type", "Genre",
        ])
        guard case let .group(name, genres) = refreshed.last else {
            return XCTFail("expected a dynamic Genre group")
        }
        XCTAssertEqual(name, "Genre")
        XCTAssertEqual(genres.map(\.name), ["Action", "Fantasy"])
        XCTAssertEqual(source.getFilterList().map(\.name), refreshed.map(\.name))
        let cachedRefresh = try await source.refreshFilterList()
        XCTAssertEqual(cachedRefresh.map(\.name), refreshed.map(\.name))
        refreshed[refreshed.count - 1] = .group(
            name: name,
            filters: genres.map { filter in
                guard case let .checkBox(name, _) = filter else { return filter }
                return .checkBox(name: name, state: true)
            }
        )

        let result = try await source.getSearchManga(
            page: 3,
            query: "hero",
            filters: refreshed
        )
        XCTAssertEqual(result.mangas.map(\.url), ["/series/demo"])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [genresURL, searchURL])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testDynamicGenreRefreshStopsAtTheSourcesLifetimeAttemptLimit() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: genresURL): CompatHTTPResponse(
                finalURL: genresURL,
                statusCode: 503,
                body: Array(#"{"error":"unavailable"}"#.utf8)
            ),
        ])
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let filters = try await source.refreshFilterList()
        XCTAssertEqual(filters.last?.name, "Tap 'Reset' to load filters")
        XCTAssertEqual(source.getFilterList().last?.name, "Tap 'Reset' to load filters")
        let laterRefresh = try await source.refreshFilterList()
        XCTAssertEqual(laterRefresh.last?.name, "Tap 'Reset' to load filters")
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [genresURL, genresURL, genresURL])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testTransientDynamicGenreRefreshRetriesOnceAndPublishesGenres() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let genresBody = #"{"data":[{"id":7,"data":{"name":"Action"}},{"id":9,"data":{"name":"Fantasy"}}]}"#
        let transport = SequencedGenreTransport(
            genresURL: genresURL,
            responses: [
                response(
                    url: genresURL,
                    statusCode: 503,
                    body: #"{"error":"temporarily unavailable"}"#
                ),
                response(url: genresURL, body: genresBody),
            ]
        )
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let refreshed = try await source.refreshFilterList()
        XCTAssertEqual(refreshed.map(\.name), [
            "Sort", "Sort Order", "Status", "Format", "Type", "Genre",
        ])
        guard case let .group(name, genres) = refreshed.last else {
            return XCTFail("expected a dynamic Genre group after the transient failure")
        }
        XCTAssertEqual(name, "Genre")
        XCTAssertEqual(genres.map(\.name), ["Action", "Fantasy"])
        XCTAssertEqual(source.getFilterList().map(\.name), refreshed.map(\.name))

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2, "the 503 should be followed by one successful retry")
        XCTAssertEqual(requests.map(\.url), [genresURL, genresURL])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testConcurrentDynamicGenreRefreshCoalescesRequestAndPublishesSameSchema() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let genresBody = #"{"data":[{"id":7,"data":{"name":"Action"}},{"id":9,"data":{"name":"Fantasy"}}]}"#
        let transport = SequencedGenreTransport(
            genresURL: genresURL,
            responses: [response(url: genresURL, body: genresBody)],
            delayNanoseconds: 100_000_000
        )
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        async let firstRefresh = source.refreshFilterList()
        async let secondRefresh = source.refreshFilterList()
        let (first, second) = try await (firstRefresh, secondRefresh)

        XCTAssertEqual(first.map(\.name), second.map(\.name))
        guard case let .group(firstName, firstGenres) = first.last,
              case let .group(secondName, secondGenres) = second.last else {
            return XCTFail("both callers should receive a dynamic Genre group")
        }
        XCTAssertEqual(firstName, "Genre")
        XCTAssertEqual(secondName, "Genre")
        XCTAssertEqual(firstGenres.map(\.name), ["Action", "Fantasy"])
        XCTAssertEqual(secondGenres.map(\.name), firstGenres.map(\.name))
        XCTAssertEqual(source.getFilterList().map(\.name), first.map(\.name))

        let requests = await transport.snapshot()
        XCTAssertEqual(
            requests.count,
            1,
            "concurrent refreshes should share the in-flight /genres request"
        )
        XCTAssertEqual(requests.first?.url, genresURL)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertNil(requests.first?.body)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testSearchQueuesBehindDynamicGenreRefreshAndUsesPublishedDefaults() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let searchURL = "https://api.voratoon.com/series?includeMeta=true&take=12&page=3&title=hero&sort=totalViews&sortOrder=desc"
        let genresBody = #"{"data":[{"id":7,"data":{"name":"Action"}},{"id":9,"data":{"name":"Fantasy"}}]}"#
        let listBody = #"{"data":[{"id":42,"data":{"slug":"demo","title":"Demo"}}],"meta":{"page":3,"lastPage":3}}"#
        let transport = SequencedGenreTransport(
            genresURL: genresURL,
            responses: [response(url: genresURL, body: genresBody)],
            additionalResponses: [
                RouteKey(method: "GET", url: searchURL): response(url: searchURL, body: listBody),
            ],
            delayNanoseconds: 100_000_000
        )
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: corpusAPK(),
            transport: transport
        )

        async let refresh = source.refreshFilterList()
        await transport.waitForFirstRequest()
        let search = try await source.getSearchManga(page: 3, query: "hero", filters: [])
        _ = try await refresh

        XCTAssertEqual(search.mangas.map(\.url), ["/series/demo"])
        XCTAssertEqual(source.getFilterList().map(\.name), [
            "Sort", "Sort Order", "Status", "Format", "Type", "Genre",
        ])
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [genresURL, searchURL])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testKomikcastRejectsMutatedGenreSchemaAndUnexpectedPreferencesBeforeTransport() async throws {
        let genresURL = "https://api.voratoon.com/genres"
        let genresBody = #"{"data":[{"id":7,"data":{"name":"Action"}}]}"#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: genresURL): response(url: genresURL, body: genresBody),
        ])
        let bytes = try corpusAPK()
        let source = try PinnedInterpretedSource.komikcast1683(
            apkBytes: bytes,
            transport: transport
        )
        var filters = try await source.refreshFilterList()
        guard case let .group(name, genres) = filters.last else {
            return XCTFail("expected dynamic Genre group")
        }
        filters[filters.count - 1] = .group(
            name: name,
            filters: genres + [.checkBox(name: "Injected", state: true)]
        )
        do {
            _ = try await source.getSearchManga(page: 1, query: "hero", filters: filters)
            XCTFail("mutated genre schema must fail closed")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .invalidInput(operation: "search filters"))
        }

        let invalidPreferences = try InterpretedExtensionPreferences(
            strings: ["unexpected": "value"]
        )
        XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.id.komikcast",
            versionName: "1.6.83",
            versionCode: 83,
            apkBytes: bytes,
            transport: transport,
            preferences: invalidPreferences
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .invalidPreferences(profile: "komikcast-voratoon-1.6.83")
            )
        }
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [genresURL])
    }

    func testKomikcastRejectsTamperedPinnedBytes() throws {
        var bytes = try corpusAPK()
        bytes[bytes.count / 2] ^= 0x01
        XCTAssertThrowsError(try PinnedInterpretedSource.komikcast1683(
            apkBytes: bytes,
            transport: RoutingTransport(responses: [:])
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .apkDigestMismatch(profile: "komikcast-voratoon-1.6.83")
            )
        }
    }
}
