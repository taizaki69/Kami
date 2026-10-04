import Foundation
import XCTest
@testable import MihonCompatKit

/// Execution evidence for one unmodified, hash/signature-pinned APK. Every
/// response is local fixture data; these cases make no live-site claim.
final class FoolSlideInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error { case unexpectedRequest }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "foolslide-exact-contract"
        private var responses: [String: [CompatHTTPResponse]]
        private var requests: [CompatHTTPRequest] = []

        init(_ responses: [String: [CompatHTTPResponse]] = [:]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard var remaining = responses[request.url], !remaining.isEmpty else {
                throw RoutingError.unexpectedRequest
            }
            let response = remaining.removeFirst()
            responses[request.url] = remaining
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private static let baseURL = "https://foolslide.test"
    private static let headers = [
        CompatHTTPHeader(name: "Referer", value: baseURL + "/"),
        CompatHTTPHeader(name: "Origin", value: baseURL),
    ]
    private static let adultBody = CompatHTTPRequestBody.form(fields: [
        CompatHTTPFormField(name: "adult", value: "true"),
    ])

    private static let popularHTML = """
    <div class="group"><a title="unused" href="/read/alpha/en/0/1/">Alpha &amp; Omega</a><img src="/uploads/alpha/thumb_alpha.jpg"></div>
    <div class="group"><a title="unused" href="/read/beta/en/0/4/">Beta</a></div>
    <div class="next"><a href="/directory/3/">Next</a></div>
    """
    private static let latestHTML = """
    <div class="group"><a title="unused" href="/read/latest/en/0/2/">Latest Manga</a><img src="/uploads/latest/thumb_latest.jpg"></div>
    """
    private static let searchHTML = """
    <div class="group"><a title="unused" href="/read/search-hit/en/0/1/">Search Hit</a><img src="/uploads/hit/thumb_hit.jpg"></div>
    <a href="/search/2/"><span class="next">next</span></a>
    """
    private static let detailsHTML = """
    <div class="info"><b>Author</b>: Test Author<br><b>Artist</b>: Test Artist<br><b>Synopsis</b>: A test summary<br></div>
    <div class="thumbnail"><img src="/uploads/alpha/cover.jpg"></div>
    <div class="list">
      <div class="element"><a title="unused" href="/read/alpha/en/0/3/">Chapter 3</a><div class="meta_r">Sunday, 2026.08.23</div></div>
      <div class="element"><a title="unused" href="/read/alpha/en/0/2/">Chapter 2</a><div class="meta_r">Sunday, 23rd August, 2026</div></div>
      <div class="element"><a title="unused" href="/read/alpha/en/0/1/">Chapter 1</a><div class="meta_r">Sunday, 16th August</div></div>
      <div class="element"><a title="unused" href="/read/alpha/en/0/0/">Prologue</a><div class="meta_r">unknown date</div></div>
    </div>
    """
    private static let fallbackDetailsHTML = """
    <div class="info"><b>Autore</b>: Another Author<br><b>Trama</b>: Another summary<br></div>
    <div class="list">
      <div class="element"><a title="unused" href="/read/alpha/en/0/2/">Chapter 2</a><div class="meta_r">2026.08.23</div></div>
      <div class="element"><a title="unused" href="/read/alpha/en/0/1/">Chapter 1</a><div class="meta_r">2026.08.16</div></div>
    </div>
    """
    private static let pagesHTML = #"<div id="chapter"><script>var pages = [{"url":"/images/001.jpg"},{"url":"https://cdn.foolslide.test/002.jpg"}];</script></div>"#

    private func apkBytes() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/foolslidecustomizable.apk")
        return [UInt8](try Data(contentsOf: path))
    }

    private func preferences(adult: Bool? = nil) throws -> InterpretedExtensionPreferences {
        try InterpretedExtensionPreferences(
            strings: ["overrideBaseUrl": Self.baseURL],
            booleans: adult.map { ["adult": $0] } ?? [:]
        )
    }

    private func htmlResponse(_ url: String, _ body: String, status: Int = 200) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: status,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(body.utf8)
        )
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: CompatHTTPRequestBody? = nil,
        cached: Bool = true
    ) -> CompatHTTPRequest {
        CompatHTTPRequest(
            url: Self.baseURL + path,
            method: method,
            headers: Self.headers,
            body: body,
            cachePolicy: cached ? CompatHTTPCachePolicy(maxAgeSeconds: 600) : nil
        )
    }

    private func midnight(year: Int, month: Int, day: Int) throws -> Int64 {
        let calendar = Calendar(identifier: .gregorian)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: 0
        )))
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    func testExactMetadataEmptyFiltersAndOverrideOnlyConfiguration() async throws {
        let transport = RoutingTransport()
        let bytes = try apkBytes()
        let unconfigured = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: bytes, transport: transport
        )
        XCTAssertEqual(unconfigured.id, 6_351_052_922_295_965_587)
        XCTAssertEqual(unconfigured.name, "FoolSlide Customizable")
        XCTAssertEqual(unconfigured.language, "other")
        XCTAssertEqual(unconfigured.baseURL, "https://127.0.0.1")
        XCTAssertTrue(unconfigured.supportsLatest)
        XCTAssertFalse(unconfigured.supportsFilterFetching)
        XCTAssertTrue(unconfigured.getFilterList().isEmpty)
        let refreshed = try await unconfigured.refreshFilterList()
        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertTrue(unconfigured.compatibilityReport().findings.isEmpty)

        let sources = try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.all.foolslidecustomizable",
            versionName: "1.6.6", versionCode: 6,
            apkBytes: bytes, transport: transport,
            preferences: preferences(adult: false)
        )
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.id, unconfigured.id)
        XCTAssertEqual(source.baseURL, Self.baseURL)
        XCTAssertTrue(source.getFilterList().isEmpty)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [])
    }

    func testPopularPaginationTitlesRelativeURLsAndThumbnailExpansion() async throws {
        let firstURL = Self.baseURL + "/directory/2/"
        let lastURL = Self.baseURL + "/directory/3/"
        let transport = RoutingTransport([
            firstURL: [htmlResponse(firstURL, Self.popularHTML)],
            lastURL: [htmlResponse(lastURL, "<html><body></body></html>")],
        ])
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: preferences()
        )
        let result = try await source.getPopularManga(page: 2)
        XCTAssertEqual(result.mangas.map(\.title), ["Alpha & Omega", "Beta"])
        XCTAssertEqual(result.mangas.map(\.url), ["/read/alpha/en/0/1/", "/read/beta/en/0/4/"])
        XCTAssertEqual(result.mangas.map(\.thumbnailURL), [Self.baseURL + "/uploads/alpha/alpha.jpg", nil])
        XCTAssertTrue(result.hasNextPage)
        let last = try await source.getPopularManga(page: 3)
        XCTAssertTrue(last.mangas.isEmpty)
        XCTAssertFalse(last.hasNextPage)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [request("/directory/2/"), request("/directory/3/")])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testLatestAndPaginatedSearchPreserveExactRequestBodiesAndSchemas() async throws {
        let latestURL = Self.baseURL + "/latest/2/"
        let searchURL = Self.baseURL + "/search/"
        let transport = RoutingTransport([
            latestURL: [htmlResponse(latestURL, Self.latestHTML)],
            searchURL: [htmlResponse(searchURL, Self.searchHTML), htmlResponse(searchURL, Self.latestHTML)],
        ])
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: preferences()
        )
        let latest = try await source.getLatestUpdates(page: 2)
        XCTAssertEqual(latest.mangas.map(\.title), ["Latest Manga"])
        XCTAssertEqual(latest.mangas.map(\.url), ["/read/latest/en/0/2/"])
        XCTAssertEqual(latest.mangas.map(\.thumbnailURL), [nil])
        XCTAssertFalse(latest.hasNextPage)
        let query = "alpha & 日本"
        let first = try await source.getSearchManga(page: 1, query: query, filters: [])
        XCTAssertEqual(first.mangas.map(\.title), ["Search Hit"])
        XCTAssertEqual(first.mangas.map(\.url), ["/read/search-hit/en/0/1/"])
        XCTAssertEqual(first.mangas.map(\.thumbnailURL), [nil])
        XCTAssertTrue(first.hasNextPage)
        let last = try await source.getSearchManga(page: 2, query: query, filters: [])
        XCTAssertEqual(last.mangas.map(\.title), ["Latest Manga"])
        XCTAssertFalse(last.hasNextPage)
        let searchRequest = request("/search/", method: "POST", body: .form(fields: [
            CompatHTTPFormField(name: "search", value: query),
        ]), cached: false)
        let requests = await transport.snapshot()
        // This exact APK submits the same search form for page 2; preserving
        // that limitation is part of the measured contract.
        XCTAssertEqual(requests, [request("/latest/2/"), searchRequest, searchRequest])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCombinedDetailsAndChaptersPreserveTitleFieldsDatesAndAdultRequest() async throws {
        let popularURL = Self.baseURL + "/directory/1/"
        let detailsURL = Self.baseURL + "/read/alpha/en/0/1/"
        let transport = RoutingTransport([
            popularURL: [htmlResponse(popularURL, Self.popularHTML)],
            detailsURL: [htmlResponse(detailsURL, Self.detailsHTML)],
        ])
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: preferences()
        )
        let popular = try await source.getPopularManga(page: 1)
        let selected = try XCTUnwrap(popular.mangas.first)
        let update = try await source.getMangaUpdate(manga: selected)
        XCTAssertEqual(update.manga.url, "/read/alpha/en/0/1/")
        XCTAssertEqual(update.manga.title, "Alpha & Omega")
        XCTAssertEqual(update.manga.author, "Test Author")
        XCTAssertEqual(update.manga.artist, "Test Artist")
        XCTAssertEqual(update.manga.description, "A test summary")
        XCTAssertEqual(update.manga.thumbnailURL, Self.baseURL + "/uploads/alpha/cover.jpg")
        XCTAssertEqual(update.manga.status, .unknown)
        XCTAssertEqual(update.manga.genres, [])
        XCTAssertTrue(update.manga.initialized)
        XCTAssertEqual(update.chapters.map(\.name), ["Chapter 3", "Chapter 2", "Chapter 1", "Prologue"])
        XCTAssertEqual(update.chapters.map(\.url), [
            "/read/alpha/en/0/3/", "/read/alpha/en/0/2/", "/read/alpha/en/0/1/", "/read/alpha/en/0/0/",
        ])
        XCTAssertEqual(update.chapters.map(\.dateUpload), [
            try midnight(year: 2026, month: 8, day: 23),
            try midnight(year: 2026, month: 8, day: 23),
            try midnight(year: year, month: 8, day: 16),
            0,
        ])
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [
            request("/directory/1/"),
            request("/read/alpha/en/0/1/", method: "POST", body: Self.adultBody),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testInjectedTransportCannotBypassResponseBoundsOrReaderHTTPSPolicy() async throws {
        let chapterURL = Self.baseURL + "/read/alpha/en/0/1/"
        let transport = RoutingTransport([chapterURL: [htmlResponse(chapterURL, Self.pagesHTML)]])
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport,
            transportPolicy: .init(maximumResponseBodyBytes: 16, allowsInsecureHTTP: false),
            preferences: preferences()
        )
        do {
            _ = try await source.getPageList(chapter: SChapterCompat(
                url: "/read/alpha/en/0/1/", name: "Chapter 1"
            ))
            XCTFail("injected responses must respect the source policy")
        } catch let error as DEXThrowable {
            guard case let .obj(object) = error.value else { return XCTFail("expected IOException") }
            XCTAssertEqual(object.dexType, "Ljava/io/IOException;")
        }
        let denied = await source.getImageRequest(page: PageCompat(
            index: 0, imageURL: "http://foolslide.test/images/001.jpg"
        ))
        XCTAssertNil(denied)
        let allowed = await source.getImageRequest(page: PageCompat(
            index: 0, imageURL: Self.baseURL + "/images/001.jpg"
        ))
        XCTAssertEqual(allowed?.url, Self.baseURL + "/images/001.jpg")
        XCTAssertNil(allowed?.sourceExecutionID)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [request("/read/alpha/en/0/1/", method: "POST", body: Self.adultBody)])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testMissingCoverUsesOldestChapterFirstImageEvenWithAdultPreferenceDisabled() async throws {
        let detailsURL = Self.baseURL + "/read/alpha/en/0/2/"
        let chapterURL = Self.baseURL + "/read/alpha/en/0/1/"
        let transport = RoutingTransport([
            detailsURL: [htmlResponse(detailsURL, Self.fallbackDetailsHTML)],
            chapterURL: [htmlResponse(chapterURL, Self.pagesHTML)],
        ])
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: preferences(adult: false)
        )
        let details = try await source.getMangaDetails(manga: SMangaCompat(
            url: "/read/alpha/en/0/2/", title: "Alpha"
        ))
        XCTAssertEqual(details.title, "Alpha")
        XCTAssertEqual(details.author, "Another Author")
        XCTAssertEqual(details.description, "Another summary")
        XCTAssertEqual(details.thumbnailURL, Self.baseURL + "/images/001.jpg")
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [
            request("/read/alpha/en/0/2/"),
            request("/read/alpha/en/0/1/"),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testPageURLsImageHeadersAndAdultPreferenceAreExact() async throws {
        let chapterURL = Self.baseURL + "/read/alpha/en/0/1/"
        let bytes = try apkBytes()
        for adult in [true, false] {
            let transport = RoutingTransport([chapterURL: [htmlResponse(chapterURL, Self.pagesHTML)]])
            let source = try PinnedInterpretedSource.foolSlideCustomizable166(
                apkBytes: bytes, transport: transport, preferences: preferences(adult: adult)
            )
            let pages = try await source.getPageList(chapter: SChapterCompat(
                url: "/read/alpha/en/0/1/", name: "Chapter 1"
            ))
            XCTAssertEqual(pages.map(\.index), [0, 1])
            XCTAssertEqual(pages.map(\.url), ["", ""])
            XCTAssertEqual(pages.map(\.imageURL), [Self.baseURL + "/images/001.jpg", "https://cdn.foolslide.test/002.jpg"])
            let localImageValue = await source.getImageRequest(page: pages[0])
            let localImage = try XCTUnwrap(localImageValue)
            XCTAssertEqual(localImage.url, Self.baseURL + "/images/001.jpg")
            XCTAssertEqual(localImage.headers, ["Referer": Self.baseURL + "/", "Origin": Self.baseURL])
            XCTAssertNil(localImage.sourceExecutionID)
            let cdnImageValue = await source.getImageRequest(page: pages[1])
            let cdnImage = try XCTUnwrap(cdnImageValue)
            XCTAssertEqual(cdnImage.url, "https://cdn.foolslide.test/002.jpg")
            XCTAssertEqual(cdnImage.headers, ["Referer": Self.baseURL + "/", "Origin": Self.baseURL])
            XCTAssertNil(cdnImage.sourceExecutionID)
            let requests = await transport.snapshot()
            XCTAssertEqual(requests, [request(
                "/read/alpha/en/0/1/", method: adult ? "POST" : "GET",
                body: adult ? Self.adultBody : nil
            )])
            XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
        }
    }

    func testHTTPFailureAndMalformedPageJSONFailPreciselyAndPermitRetry() async throws {
        let popularURL = Self.baseURL + "/directory/1/"
        let chapterURL = Self.baseURL + "/read/alpha/en/0/1/"
        let transport = RoutingTransport([
            popularURL: [htmlResponse(popularURL, "blocked", status: 403), htmlResponse(popularURL, Self.popularHTML)],
            chapterURL: [htmlResponse(chapterURL, "<script>var pages = [{invalid}];</script>"), htmlResponse(chapterURL, Self.pagesHTML)],
        ])
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: preferences()
        )
        do {
            _ = try await source.getPopularManga(page: 1)
            XCTFail("403 must fail before parsing")
        } catch let error as DEXThrowable {
            guard case let .obj(object) = error.value else { return XCTFail("expected HttpException") }
            XCTAssertEqual(object.dexType, "Leu/kanade/tachiyomi/network/HttpException;")
            XCTAssertEqual(object.fields["code"].flatMap { value -> Int32? in
                if case let .int(code) = value { return code }; return nil
            }, 403)
        }
        let retried = try await source.getPopularManga(page: 1)
        XCTAssertEqual(retried.mangas.map(\.title), ["Alpha & Omega", "Beta"])
        let chapter = SChapterCompat(url: "/read/alpha/en/0/1/", name: "Chapter 1")
        do {
            _ = try await source.getPageList(chapter: chapter)
            XCTFail("malformed page JSON must fail")
        } catch let error as DEXThrowable {
            guard case let .obj(object) = error.value else { return XCTFail("expected SerializationException") }
            XCTAssertEqual(object.dexType, "Lkotlinx/serialization/SerializationException;")
        }
        let pages = try await source.getPageList(chapter: chapter)
        XCTAssertEqual(pages.map(\.imageURL), [Self.baseURL + "/images/001.jpg", "https://cdn.foolslide.test/002.jpg"])
        let requests = await transport.snapshot()
        XCTAssertEqual(requests, [
            request("/directory/1/"), request("/directory/1/"),
            request("/read/alpha/en/0/1/", method: "POST", body: Self.adultBody),
            request("/read/alpha/en/0/1/", method: "POST", body: Self.adultBody),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
}
