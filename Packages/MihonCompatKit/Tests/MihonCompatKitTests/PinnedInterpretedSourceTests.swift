import Foundation
import XCTest
@testable import MihonCompatKit

final class PinnedInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse
    }

    /// Reentrant while its deterministic delay is suspended. If the source
    /// fails to serialize VM ownership, `maximumActiveRequests` rises above 1.
    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "batcave-adapter-test"

        private let responses: [String: CompatHTTPResponse]
        private let delayNanoseconds: UInt64
        private var recordedRequests: [CompatHTTPRequest] = []
        private var activeRequests = 0
        private var maximumActiveRequests = 0

        init(
            responses: [String: CompatHTTPResponse],
            delayNanoseconds: UInt64 = 0
        ) {
            self.responses = responses
            self.delayNanoseconds = delayNanoseconds
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            recordedRequests.append(request)
            activeRequests += 1
            maximumActiveRequests = Swift.max(maximumActiveRequests, activeRequests)
            defer { activeRequests -= 1 }

            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } else {
                await Task.yield()
            }
            guard let response = responses[request.url] else {
                throw RoutingError.missingResponse
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] {
            recordedRequests
        }

        func peakConcurrency() -> Int {
            maximumActiveRequests
        }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/MihonCompatKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/MihonCompatKit
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami (repo root)
            .appendingPathComponent("Tests/corpus/batcave.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK batcave.apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func response(
        url: String,
        body: String,
        contentType: String = "text/html; charset=utf-8"
    ) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: contentType)],
            body: Array(body.utf8)
        )
    }

    private func routes() -> [String: CompatHTTPResponse] {
        let popularURL = "https://batcave.biz/comix/"
        let latestURL = "https://batcave.biz/page/3"
        let searchURL = "https://batcave.biz/search/alpha+beta/page/2/"
        let detailURL = "https://batcave.biz/comic/adapter-hero"
        let pagesURL = "https://batcave.biz/engine/ajax/controller.php?mod=api&action=reader/getChapterData"

        let popularHTML = """
        <div id="dle-content">
          <article class="readed">
            <div class="readed__title"><a href="/comic/popular-hit">Popular Hit</a></div>
            <img data-src="/uploads/popular-hit.jpg">
          </article>
        </div>
        <div class="pagination__pages"><span>1</span><a href="/comix/page/2/">2</a></div>
        """
        let latestHTML = """
        <div id="content-load">
          <article class="latest grid-item">
            <div class="latest__title"><a href="/comic/latest-hit">Latest Hit</a></div>
            <div class="latest__img"><img src="/uploads/latest-hit.jpg"></div>
          </article>
        </div>
        <li class="pagination"><a href="/page/4">Next</a></li>
        """
        let searchHTML = """
        <div id="dle-content">
          <article class="readed">
            <div class="readed__title"><a href="/comic/search-hit">Search Hit</a></div>
            <img data-src="/uploads/search-hit.jpg">
          </article>
        </div>
        <div class="pagination__pages"><span>1</span></div>
        """
        let detailHTML = """
        <header class="page__header"><h1>Adapter Hero</h1></header>
        <div class="page__poster"><img src="/uploads/adapter-hero.jpg"></div>
        <ul class="page__list">
          <li><div>Publisher</div><a>Bat Publisher</a></li>
          <li><div>Year</div><a>2026</a></li>
          <li><div>Writer</div><a>Writer Name</a></li>
          <li><div>Artist</div><a>Artist Name</a></li>
          <li><div>Release type</div>Ongoing</li>
        </ul>
        <div class="page__text">Adapter frontier.</div>
        <div class="page__tags"><a>Action</a><a>Adventure</a></div>
        <script>
        window.__DATA__ = {"news_id":42,"chapters":[{"id":7,"posi":1.5,"title":"Chapter 1.5","date":"23.8.2026"},{"id":8,"posi":2.0,"title":"Chapter 2","date":"not-a-date"}],"xhash":"?token=test"};
        </script>
        """
        let pagesJSON = #"{"data":{"images":[" /uploads/page-one.jpg ","https://cdn.example/page-two.jpg "]}}"#

        return [
            popularURL: response(url: popularURL, body: popularHTML),
            latestURL: response(url: latestURL, body: latestHTML),
            searchURL: response(url: searchURL, body: searchHTML),
            detailURL: response(url: detailURL, body: detailHTML),
            pagesURL: response(
                url: pagesURL,
                body: pagesJSON,
                contentType: "application/json; charset=utf-8"
            ),
        ]
    }

    func testBatCaveProfileExposesEveryProvenKamiSourceOperation() async throws {
        let transport = RoutingTransport(responses: routes())
        let source = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: transport
        )

        XCTAssertEqual(source.id, 7_422_099_479_605_463_706)
        XCTAssertEqual(source.name, "BatCave")
        XCTAssertEqual(source.language, "en")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertEqual(source.baseURL, "https://batcave.biz")
        XCTAssertTrue(source.getFilterList().isEmpty)

        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.count, 1)
        XCTAssertEqual(popular.mangas[0].url, "/comic/popular-hit")
        XCTAssertEqual(popular.mangas[0].title, "Popular Hit")
        XCTAssertEqual(
            popular.mangas[0].thumbnailURL,
            "https://batcave.biz/uploads/popular-hit.jpg"
        )
        XCTAssertTrue(popular.hasNextPage)

        let latest = try await source.getLatestUpdates(page: 3)
        XCTAssertEqual(latest.mangas.count, 1)
        XCTAssertEqual(latest.mangas[0].url, "/comic/latest-hit")
        XCTAssertEqual(latest.mangas[0].title, "Latest Hit")
        XCTAssertTrue(latest.hasNextPage)

        let search = try await source.getSearchManga(
            page: 2,
            query: "  alpha beta  ",
            filters: []
        )
        XCTAssertEqual(search.mangas.count, 1)
        XCTAssertEqual(search.mangas[0].url, "/comic/search-hit")
        XCTAssertEqual(search.mangas[0].title, "Search Hit")
        XCTAssertFalse(search.hasNextPage)

        let inputManga = SMangaCompat(
            url: "/comic/adapter-hero",
            title: "Uninitialized Adapter Hero"
        )
        let details = try await source.getMangaDetails(manga: inputManga)
        XCTAssertEqual(details.url, "/comic/adapter-hero")
        XCTAssertEqual(details.title, "Adapter Hero")
        XCTAssertEqual(
            details.thumbnailURL,
            "https://batcave.biz/uploads/adapter-hero.jpg"
        )
        XCTAssertEqual(details.description, "Bat Publisher — 2026\n\nAdapter frontier.")
        XCTAssertEqual(details.author, "Writer Name")
        XCTAssertEqual(details.artist, "Artist Name")
        XCTAssertEqual(details.genres, ["Action", "Adventure", "Comic"])
        XCTAssertEqual(details.status.rawValue, MangaStatus.ongoing.rawValue)

        let chapters = try await source.getChapterList(manga: inputManga)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].url, "/reader/42/7?token=test")
        XCTAssertEqual(chapters[0].name, "Chapter 1.5")
        XCTAssertEqual(chapters[0].chapterNumber, 1.5)
        XCTAssertEqual(chapters[1].url, "/reader/42/8?token=test")

        let update = try await source.getMangaUpdate(manga: inputManga)
        XCTAssertEqual(update.manga.title, "Adapter Hero")
        XCTAssertEqual(update.chapters.count, 2)

        let pages = try await source.getPageList(chapter: chapters[0])
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].index, 0)
        XCTAssertEqual(pages[0].imageURL, "https://batcave.biz/uploads/page-one.jpg")
        XCTAssertEqual(pages[1].index, 1)
        XCTAssertEqual(pages[1].imageURL, "https://cdn.example/page-two.jpg")

        let resolvedImageRequest = await source.getImageRequest(page: pages[0])
        let imageRequest = try XCTUnwrap(resolvedImageRequest)
        XCTAssertEqual(imageRequest.url, "https://batcave.biz/uploads/page-one.jpg")
        XCTAssertTrue(imageRequest.headers.isEmpty)
        let invalidImageRequest = await source.getImageRequest(page: PageCompat(
            index: 0,
            imageURL: "file:///private/reader-page.jpg"
        ))
        XCTAssertNil(invalidImageRequest)

        do {
            _ = try await source.getSearchManga(page: 1, query: "   ", filters: [])
            XCTFail("expected blank search to remain explicitly unsupported")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .unsupportedOperation("blank search"))
        }
        do {
            _ = try await source.getSearchManga(
                page: 1,
                query: "hero",
                filters: [.header("unsupported")]
            )
            XCTFail("expected filtered search to remain explicitly unsupported")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .unsupportedOperation("filtered search"))
        }

        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [
            CompatHTTPRequest(
                url: "https://batcave.biz/comix/",
                method: "POST",
                body: .form(fields: [
                    CompatHTTPFormField(name: "dlenewssortby", value: "rating"),
                    CompatHTTPFormField(name: "dledirection", value: "desc"),
                    CompatHTTPFormField(name: "set_new_sort", value: "dle_sort_cat_1"),
                    CompatHTTPFormField(name: "set_direction_sort", value: "dle_direction_cat_1"),
                ])
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/page/3",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/search/alpha+beta/page/2/",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/comic/adapter-hero",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/comic/adapter-hero",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/comic/adapter-hero",
                cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
            ),
            CompatHTTPRequest(
                url: "https://batcave.biz/engine/ajax/controller.php?mod=api&action=reader/getChapterData",
                method: "POST",
                body: .text(
                    value: #"{"news_id":"42","chapter_id":"7"}"#,
                    mediaType: "application/json"
                )
            ),
        ])
    }

    func testPinnedImageRequestsFollowTheConfiguredTransportPolicy() async throws {
        let page = PageCompat(index: 0, imageURL: "http://images.example/page.jpg")

        let strictSource = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: RoutingTransport(responses: [:]),
            transportPolicy: CompatHTTPTransportPolicy(allowsInsecureHTTP: false)
        )
        XCTAssertFalse(strictSource.transportPolicy.allowsInsecureHTTP)
        let strictRequest = await strictSource.getImageRequest(page: page)
        XCTAssertNil(strictRequest)

        let explicitlyInsecureSource = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: RoutingTransport(responses: [:]),
            transportPolicy: CompatHTTPTransportPolicy(allowsInsecureHTTP: true)
        )
        XCTAssertTrue(explicitlyInsecureSource.transportPolicy.allowsInsecureHTTP)
        let insecureRequest = await explicitlyInsecureSource.getImageRequest(page: page)
        XCTAssertEqual(
            insecureRequest?.url,
            page.imageURL
        )
    }

    func testBatCaveProfileRejectsAPKTamperingBeforeParsing() throws {
        var apk = try corpusAPK()
        apk[apk.count - 1] ^= 0x01

        let transport = RoutingTransport(responses: [:])
        XCTAssertThrowsError(try PinnedInterpretedSource.batCave169(
            apkBytes: apk,
            transport: transport
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .apkDigestMismatch(profile: "batcave-1.6.9")
            )
        }
    }

    func testBatCaveRuntimeSerializesConcurrentSourceCalls() async throws {
        let transport = RoutingTransport(
            responses: routes(),
            delayNanoseconds: 25_000_000
        )
        let source = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: transport
        )

        async let popular = source.getPopularManga(page: 1)
        async let latest = source.getLatestUpdates(page: 3)
        _ = try await (popular, latest)

        let requestCount = await transport.snapshot().count
        let peakConcurrency = await transport.peakConcurrency()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(peakConcurrency, 1)
    }
}
