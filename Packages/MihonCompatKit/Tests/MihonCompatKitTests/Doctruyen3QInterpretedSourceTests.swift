import Foundation
import XCTest
@testable import MihonCompatKit

final class Doctruyen3QInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case unexpectedRequest
    }

    private actor RejectingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "doctruyen3q-construction-probe"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("construction must not execute a request: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "doctruyen3q-routing-test"
        private let responses: [String: CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []

        init(responses: [String: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard let response = responses[request.url] else {
                throw RoutingError.unexpectedRequest
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
            .appendingPathComponent("Tests/corpus/measurement/doctruyen3q.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip(
                "corpus APK doctruyen3q.apk not present — run scripts/fetch_corpus.sh"
            )
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func htmlResponse(url: String, body: String) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(body.utf8)
        )
    }

    private static let expectedReferer = [
        CompatHTTPHeader(name: "Referer", value: "https://doctruyen3qhub.vip/"),
    ]

    // The categories-detail nav is DocTruyen3Q's overridden genre selector;
    // li:not(.active) rows carry href + display text pairs.
    private static let genresHTML = #"<!DOCTYPE html><html><head><title></title></head><body><div class="categories-detail"><ul class="nav"><li><a href="/the-loai/action/">Action</a></li><li><a href="/the-loai/adventure/">Adventure</a></li></ul></div></body></html>"#

    // One entry uses data-src with an empty src (lazy image), the other a plain
    // src; a.next-page drives hasNextPage.
    private static let listHTML = #"<!DOCTYPE html><html><head><title></title></head><body><div class="item-manga"><div class="item"><h3><a href="https://doctruyen3qhub.vip/truyen/kiem-dung">Kiếm Dũng</a></h3><div class="image"><img data-src="https://doctruyen3qhub.vip/uploads/kiem-dung.jpg" src=""></div></div></div><div class="item-manga"><div class="item"><h3><a href="https://doctruyen3qhub.vip/truyen/thien-linh">Thien Linh</a></h3><div class="image"><img src="https://doctruyen3qhub.vip/uploads/thien-linh.jpg"></div></div></div><a class="next-page" href="/hot?page=2">Next</a></body></html>"#

    // li[style] and li.heading rows must be filtered from the chapter list;
    // absolute dd-MM-yyyy dates compile to 0 through the MangaSum suffix path.
    private static let detailsHTML = #"<!DOCTYPE html><html><body><h1 class="title-manga">Kiếm Dũng</h1><li class="author"><p class="col-sm-8">Tác giả A, Tác giả B</p></li><p class="detail-summary">Resumen uno</p><p class="detail-summary">  Resumen dos </p><li class="status"><p class="detail-info"><span>Đang tiến hành</span></p></li><li class="category"><p class="detail-info"><a href="/the-loai/action/">Action</a><a href="/the-loai/adventure/">Adventure</a></p></li><img class="image-comic" src="/uploads/cover.jpg"><div class="list-chapter"><li class="row" style="display:none"><a href="/skip">skip</a></li><li class="heading"><a href="/skip2">heading</a></li><li class="row"><a href="/truyen/kiem-dung/chap-2">Chương 2</a><div class="chapters"></div><div>23-08-2026</div></li><li class="row"><a href="/truyen/kiem-dung/chap-1">Chương 1</a><div class="chapters"></div><div>20-08-2026</div></li></div></body></html>"#

    // The middle page has an empty src and relies on the abs:data-src fallback;
    // the third page repeats the first image and must be deduplicated.
    private static let pagesHTML = #"<!DOCTYPE html><html><body><div class="page-chapter" id="page_1"><img src="https://img.doctruyen3q.vip/chap-1/01.jpg"></div><div class="page-chapter" id="page_2"><img src="" data-src="https://img.doctruyen3q.vip/chap-1/02.jpg"></div><div class="page-chapter" id="page_3"><img src="https://img.doctruyen3q.vip/chap-1/01.jpg"></div></body></html>"#

    func testExactDoctruyen3QConstructsAndExposesInitialFilters() throws {
        let bytes = try corpusAPK()
        let transport = RejectingTransport()
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: bytes,
            transport: transport
        )

        XCTAssertEqual(source.id, 6_168_143_505_244_976_507)
        XCTAssertEqual(source.name, "DocTruyen3Q")
        XCTAssertEqual(source.language, "vi")
        XCTAssertEqual(source.baseURL, "https://doctruyen3qhub.vip")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertTrue(source.supportsFilterFetching)
        XCTAssertTrue(InterpretedExtensionProfileCatalog.supports(
            packageName: "eu.kanade.tachiyomi.extension.vi.doctruyen3q",
            versionName: "1.6.38",
            versionCode: 38
        ))
        XCTAssertEqual(
            InterpretedExtensionProfileCatalog.expectedSourceIDs(
                packageName: "eu.kanade.tachiyomi.extension.vi.doctruyen3q",
                versionName: "1.6.38",
                versionCode: 38
            ),
            [6_168_143_505_244_976_507]
        )

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 3)
        guard case let .select(statusName, statusValues, statusState) = filters[0],
              case .separator = filters[1],
              case let .header(loadHint) = filters[2] else {
            return XCTFail("expected the exact initial filter list")
        }
        XCTAssertEqual(statusName, "Trạng thái")
        XCTAssertEqual(statusValues, ["Tất cả", "Đang tiến hành", "Hoàn thành"])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(loadHint, "Tap 'Reset' to load filters")
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let invalidPreferences = try InterpretedExtensionPreferences(
            strings: ["unexpected": "value"]
        )
        XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.vi.doctruyen3q",
            versionName: "1.6.38",
            versionCode: 38,
            apkBytes: bytes,
            transport: transport,
            preferences: invalidPreferences
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .invalidPreferences(profile: "doctruyen3q-1.6.38")
            )
        }

        var tampered = bytes
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: tampered,
            transport: transport
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .apkDigestMismatch(profile: "doctruyen3q-1.6.38")
            )
        }
    }

    func testExactDoctruyen3QRefreshesDynamicGenres() async throws {
        let genresURL = "https://doctruyen3qhub.vip/tim-truyen"
        let transport = RoutingTransport(responses: [
            genresURL: htmlResponse(url: genresURL, body: Self.genresHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let filters = try await source.refreshFilterList()
        XCTAssertEqual(filters.map(\.name), ["Trạng thái", "Thể loại"])
        guard case let .select(statusName, statusValues, statusState) = filters[0],
              case let .select(genreName, genreValues, genreState) = filters[1] else {
            return XCTFail("expected status and genre selects")
        }
        XCTAssertEqual(statusName, "Trạng thái")
        XCTAssertEqual(statusValues, ["Tất cả", "Đang tiến hành", "Hoàn thành"])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(genreName, "Thể loại")
        XCTAssertEqual(genreValues, ["Tất cả", "Action", "Adventure"])
        XCTAssertEqual(genreState, 0)
        let cached = source.getFilterList()
        XCTAssertEqual(cached.map(\.name), filters.map(\.name))
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, genresURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QPopularEntriesAndRequest() async throws {
        let hotURL = "https://doctruyen3qhub.vip/hot"
        let transport = RoutingTransport(responses: [
            hotURL: htmlResponse(url: hotURL, body: Self.listHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getPopularManga(page: 1)
        XCTAssertEqual(result.mangas.count, 2)
        XCTAssertEqual(result.mangas[0].url, "/truyen/kiem-dung")
        XCTAssertEqual(result.mangas[0].title, "Kiếm Dũng")
        XCTAssertEqual(
            result.mangas[0].thumbnailURL,
            "https://doctruyen3qhub.vip/uploads/kiem-dung.jpg"
        )
        XCTAssertEqual(result.mangas[1].url, "/truyen/thien-linh")
        XCTAssertEqual(result.mangas[1].title, "Thien Linh")
        XCTAssertEqual(
            result.mangas[1].thumbnailURL,
            "https://doctruyen3qhub.vip/uploads/thien-linh.jpg"
        )
        XCTAssertTrue(result.hasNextPage)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, hotURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QLatestEntriesAndRequest() async throws {
        let base = "https://doctruyen3qhub.vip"
        let transport = RoutingTransport(responses: [
            base: htmlResponse(url: base, body: Self.listHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getLatestUpdates(page: 1)
        XCTAssertEqual(result.mangas.map(\.title), ["Kiếm Dũng", "Thien Linh"])
        XCTAssertTrue(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, base)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QSearchWithoutQueryUsesPageParam() async throws {
        let searchURL = "https://doctruyen3qhub.vip/tim-truyen?page=1"
        let transport = RoutingTransport(responses: [
            searchURL: htmlResponse(url: searchURL, body: Self.listHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getSearchManga(
            page: 1,
            query: "",
            filters: source.getFilterList()
        )
        XCTAssertEqual(result.mangas.map(\.title), ["Kiếm Dũng", "Thien Linh"])
        XCTAssertTrue(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, searchURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QSearchWithQueryUsesKeywordParam() async throws {
        let searchURL = "https://doctruyen3qhub.vip/tim-truyen?keyword=ki%E1%BA%BFm"
        let transport = RoutingTransport(responses: [
            searchURL: htmlResponse(url: searchURL, body: Self.listHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getSearchManga(
            page: 1,
            query: "kiếm",
            filters: source.getFilterList()
        )
        XCTAssertEqual(result.mangas.map(\.title), ["Kiếm Dũng", "Thien Linh"])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, searchURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QSearchWithGenreAndStatusFilters() async throws {
        let searchURL = "https://doctruyen3qhub.vip/tim-truyen/%2Fthe-loai?status=1&page=1"
        let transport = RoutingTransport(responses: [
            "https://doctruyen3qhub.vip/tim-truyen": htmlResponse(
                url: "https://doctruyen3qhub.vip/tim-truyen",
                body: Self.genresHTML
            ),
            searchURL: htmlResponse(url: searchURL, body: Self.listHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        var filters = try await source.refreshFilterList()
        XCTAssertEqual(filters.count, 2)
        filters[0] = .select(name: "Trạng thái", values: ["Tất cả", "Đang tiến hành", "Hoàn thành"], state: 1)
        filters[1] = .select(name: "Thể loại", values: ["Tất cả", "Action", "Adventure"], state: 2)

        let result = try await source.getSearchManga(
            page: 1,
            query: "",
            filters: filters
        )
        XCTAssertEqual(result.mangas.map(\.title), ["Kiếm Dũng", "Thien Linh"])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.url, searchURL)
        XCTAssertEqual(requests.last?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QMangaDetailsFields() async throws {
        let detailsURL = "https://doctruyen3qhub.vip/truyen/kiem-dung"
        let transport = RoutingTransport(responses: [
            detailsURL: htmlResponse(url: detailsURL, body: Self.detailsHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let details = try await source.getMangaDetails(
            manga: SMangaCompat(url: "/truyen/kiem-dung", title: "old")
        )
        XCTAssertEqual(details.title, "Kiếm Dũng")
        XCTAssertEqual(details.author, "Tác giả A, Tác giả B")
        XCTAssertEqual(details.description, "Resumen uno\nResumen dos")
        XCTAssertEqual(details.status, .ongoing)
        XCTAssertEqual(details.genres, ["Action", "Adventure"])
        XCTAssertEqual(
            details.thumbnailURL,
            "https://doctruyen3qhub.vip/uploads/cover.jpg"
        )
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, detailsURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QChapterListFiltersRowsAndDates() async throws {
        let detailsURL = "https://doctruyen3qhub.vip/truyen/kiem-dung"
        let transport = RoutingTransport(responses: [
            detailsURL: htmlResponse(url: detailsURL, body: Self.detailsHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let chapters = try await source.getChapterList(
            manga: SMangaCompat(url: "/truyen/kiem-dung", title: "Kiếm Dũng")
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].url, "/truyen/kiem-dung/chap-2")
        XCTAssertEqual(chapters[0].name, "Chương 2")
        XCTAssertEqual(chapters[0].dateUpload, 0)
        XCTAssertEqual(chapters[1].url, "/truyen/kiem-dung/chap-1")
        XCTAssertEqual(chapters[1].name, "Chương 1")
        XCTAssertEqual(chapters[1].dateUpload, 0)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, detailsURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }

    func testExactDoctruyen3QPageListFallsBackAndDedupes() async throws {
        let chapterURL = "https://doctruyen3qhub.vip/truyen/kiem-dung/chap-1"
        let transport = RoutingTransport(responses: [
            chapterURL: htmlResponse(url: chapterURL, body: Self.pagesHTML),
        ])
        let source = try PinnedInterpretedSource.docTruyen3Q1638(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let pages = try await source.getPageList(chapter: SChapterCompat(
            url: "/truyen/kiem-dung/chap-1",
            name: "Chương 1"
        ))
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://img.doctruyen3q.vip/chap-1/01.jpg",
            "https://img.doctruyen3q.vip/chap-1/02.jpg",
        ])
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url, chapterURL)
        XCTAssertEqual(requests.first?.headers, Self.expectedReferer)
    }
}
