import Foundation
import XCTest
@testable import MihonCompatKit

final class EternalMangasInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case unexpectedRequest
    }

    private actor RejectingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "eternalmangas-construction-probe"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("construction must not execute a request: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "eternalmangas-routing-test"
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

    private func response(url: String, contentType: String, body: String) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: contentType)],
            body: Array(body.utf8)
        )
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/eternalmangas.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip(
                "corpus APK measurement/eternalmangas.apk not present"
            )
        }
        return [UInt8](try Data(contentsOf: path))
    }

    func testExactEternalMangasConstructsAndExposesInitialFilters() throws {
        let bytes = try corpusAPK()
        let transport = RejectingTransport()
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: bytes,
            transport: transport
        )

        XCTAssertEqual(source.id, 1_533_901_034_425_595_323)
        XCTAssertEqual(source.name, "EternalMangas")
        XCTAssertEqual(source.language, "es")
        XCTAssertEqual(source.baseURL, "https://eternalmangas.org")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertFalse(source.supportsFilterFetching)
        XCTAssertTrue(InterpretedExtensionProfileCatalog.supports(
            packageName: "eu.kanade.tachiyomi.extension.es.eternalmangas",
            versionName: "1.6.28",
            versionCode: 28
        ))
        XCTAssertEqual(
            InterpretedExtensionProfileCatalog.expectedSourceIDs(
                packageName: "eu.kanade.tachiyomi.extension.es.eternalmangas",
                versionName: "1.6.28",
                versionCode: 28
            ),
            [1_533_901_034_425_595_323]
        )

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 6)
        XCTAssertEqual(filters.map(\.name), [
            "Status", "Type", "Sort", "Sort direction", "", "Pulse 'Restablecer' para cargar los filtros",
        ])
        guard case let .select(statusName, statusValues, statusState) = filters[0],
              case let .select(typeName, typeValues, typeState) = filters[1],
              case let .select(sortName, sortValues, sortState) = filters[2],
              case let .select(directionName, directionValues, directionState) = filters[3],
              case .separator = filters[4],
              case let .header(loadHint) = filters[5] else {
            return XCTFail("expected the exact initial EternalMangas select filters")
        }
        XCTAssertEqual(statusName, "Status")
        XCTAssertEqual(statusValues, [
            "ALL", "Ongoing", "Completed", "Canceled", "Dropped", "Coming Soon", "Mass Released",
        ])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(typeName, "Type")
        XCTAssertEqual(typeValues, ["ALL", "Manga", "Manhua", "Manhwa", "Russian", "Spanish"])
        XCTAssertEqual(typeState, 0)
        XCTAssertEqual(sortName, "Sort")
        XCTAssertEqual(sortValues, ["Latest Update", "Popularity", "Date Added", "Chapter Count", "A-Z"])
        XCTAssertEqual(sortState, 0)
        XCTAssertEqual(directionName, "Sort direction")
        XCTAssertEqual(directionValues, ["Descending", "Ascending"])
        XCTAssertEqual(directionState, 0)
        XCTAssertEqual(loadHint, "Pulse 'Restablecer' para cargar los filtros")
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let invalidPreferences = try InterpretedExtensionPreferences(
            strings: ["unexpected": "value"]
        )
        XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.es.eternalmangas",
            versionName: "1.6.28",
            versionCode: 28,
            apkBytes: bytes,
            transport: transport,
            preferences: invalidPreferences
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .invalidPreferences(profile: "eternalmangas-1.6.28")
            )
        }

        var tampered = bytes
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: tampered,
            transport: transport
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .apkDigestMismatch(profile: "eternalmangas-1.6.28")
            )
        }
    }



    func testExactEternalMangasExecutesPageList() async throws {
        let pagesURL = "https://api.eternalmangas.org/api/chapter?chapterId=101"
        let viewsURL = "https://api.eternalmangas.org/api/analytics/updateViews"
        let body = #"{"chapter":{"images":[{"url":"https://cdn.example/p01.jpg","order":1},{"url":"https://cdn.example/p02.jpg","order":2}]}}"#
        let transport = RoutingTransport(responses: [
            pagesURL: response(url: pagesURL, contentType: "application/json; charset=utf-8", body: body),
            viewsURL: response(url: viewsURL, contentType: "application/json; charset=utf-8", body: ""),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let pages = try await source.getPageList(chapter: SChapterCompat(
            url: "/series/heroe/cap-1#101",
            name: "Chapter 1",
            memo: ["seriesSlug": "heroe", "slug": "cap-1", "id": "101"]
        ))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.index, 0)
        XCTAssertEqual(pages.first?.imageURL, "https://cdn.example/p01.jpg")
        XCTAssertEqual(pages.last?.index, 1)
        XCTAssertEqual(pages.last?.imageURL, "https://cdn.example/p02.jpg")

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let pagesRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(pagesRequest.method, "GET")
        XCTAssertEqual(pagesRequest.url, pagesURL)
        XCTAssertNil(pagesRequest.body)
        XCTAssertEqual(pagesRequest.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(pagesRequest.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        let viewsRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(viewsRequest.method, "POST")
        XCTAssertEqual(viewsRequest.url, viewsURL)
        XCTAssertEqual(
            viewsRequest.body,
            CompatHTTPRequestBody.text(
                value: "{\"postId\":null,\"chapterId\":101}",
                mediaType: "application/json"
            )
        )
        XCTAssertNil(viewsRequest.cachePolicy)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testExactEternalMangasExecutesChapterList() async throws {
        let detailsURL = "https://api.eternalmangas.org/api/post?postSlug=heroe"
        let detailsBody = #"{"post":{"id":789,"slug":"heroe","postTitle":"Heroe","chapters":[{"id":101,"slug":"cap-1","number":1,"title":"","createdAt":"2026-08-23T12:34:56Z"},{"id":102,"slug":"cap-1-5","number":1.5,"createdAt":"2026-08-24T09:00:00Z","isLocked":true}]}}"#
        let viewsURL = "https://api.eternalmangas.org/api/analytics/updateViews"
        let transport = RoutingTransport(responses: [
            detailsURL: response(url: detailsURL, contentType: "application/json; charset=utf-8", body: detailsBody),
            viewsURL: response(url: viewsURL, contentType: "application/json; charset=utf-8", body: ""),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let chapters = try await source.getChapterList(manga: SMangaCompat(url: "heroe#789", title: "Heroe"))
        XCTAssertEqual(chapters.count, 1)
        let chapter = try XCTUnwrap(chapters.first)
        XCTAssertEqual(chapter.url, "/series/heroe/cap-1#101")
        XCTAssertEqual(chapter.name, "Chapter 1")
        XCTAssertEqual(chapter.dateUpload, 1_787_488_496_000)
        XCTAssertFalse(chapter.locked)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let detailsRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(detailsRequest.method, "GET")
        XCTAssertEqual(detailsRequest.url, detailsURL)
        XCTAssertNil(detailsRequest.body)
        XCTAssertEqual(detailsRequest.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(detailsRequest.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        let viewsRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(viewsRequest.method, "POST")
        XCTAssertEqual(viewsRequest.url, viewsURL)
        XCTAssertEqual(
            viewsRequest.body,
            CompatHTTPRequestBody.text(
                value: "{\"postId\":789,\"chapterId\":null}",
                mediaType: "application/json"
            )
        )
        XCTAssertNil(viewsRequest.cachePolicy)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
    func testExactEternalMangasExecutesMangaDetails() async throws {
        let detailsURL = "https://api.eternalmangas.org/api/post?postSlug=heroe"
        let viewsURL = "https://api.eternalmangas.org/api/analytics/updateViews"
        let body = #"{"post":{"id":789,"slug":"heroe","postTitle":"Heroe","postContent":"<b>Resumen</b> del heroe","featuredImage":"https://cdn.example/heroe.jpg","alternativeTitles":"Etiqueta alternativa","author":"Autor","artist":"Artista","seriesType":"MANHUA","seriesStatus":"ONGOING","genres":[{"id":5,"name":"Accion"}]}}"#
        let transport = RoutingTransport(responses: [
            detailsURL: response(url: detailsURL, contentType: "application/json; charset=utf-8", body: body),
            viewsURL: response(url: viewsURL, contentType: "application/json; charset=utf-8", body: ""),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let details = try await source.getMangaDetails(manga: SMangaCompat(url: "heroe#789", title: "Heroe"))
        XCTAssertEqual(details.url, "heroe#789")
        XCTAssertEqual(details.title, "Heroe")
        XCTAssertEqual(details.thumbnailURL, "https://cdn.example/heroe.jpg")
        XCTAssertEqual(details.author, "Autor")
        XCTAssertEqual(details.artist, "Artista")
        XCTAssertEqual(details.description, "Resumen del heroe\n\nAlternative Names: Etiqueta alternativa")
        XCTAssertEqual(details.genres, ["Manhua", "Accion"])
        XCTAssertEqual(details.status, .ongoing)
        XCTAssertEqual(details.memo["id"], "789")
        XCTAssertEqual(details.memo["slug"], "heroe")
        XCTAssertTrue(details.initialized)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let detailsRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(detailsRequest.method, "GET")
        XCTAssertEqual(detailsRequest.url, detailsURL)
        XCTAssertNil(detailsRequest.body)
        XCTAssertEqual(detailsRequest.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(detailsRequest.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        let viewsRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(viewsRequest.method, "POST")
        XCTAssertEqual(viewsRequest.url, viewsURL)
        XCTAssertEqual(
            viewsRequest.body,
            CompatHTTPRequestBody.text(
                value: "{\"postId\":789,\"chapterId\":null}",
                mediaType: "application/json"
            )
        )
        XCTAssertNil(viewsRequest.cachePolicy)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testExactEternalMangasExecutesSearch() async throws {
        let searchURL = "https://api.eternalmangas.org/api/query?page=1&perPage=18&searchTerm=hero&seriesStatus=&seriesType=&orderBy=lastChapterAddedAt&orderDirection=desc"
        let body = #"{"posts":[{"id":789,"slug":"heroe","postTitle":"Heroe","postContent":"<b>Resumen</b> del heroe","featuredImage":"https://cdn.example/heroe.jpg","seriesType":"MANHUA","seriesStatus":"ONGOING","genres":[{"id":5,"name":"Accion"}]}],"totalCount":1}"#
        let transport = RoutingTransport(responses: [
            searchURL: response(url: searchURL, contentType: "application/json; charset=utf-8", body: body),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getSearchManga(
            page: 1,
            query: "hero",
            filters: source.getFilterList()
        )
        XCTAssertEqual(result.mangas.count, 1)
        XCTAssertEqual(result.mangas.first?.url, "heroe#789")
        XCTAssertEqual(result.mangas.first?.title, "Heroe")
        XCTAssertEqual(result.mangas.first?.description, "Resumen del heroe")
        XCTAssertEqual(result.mangas.first?.genres, ["Manhua", "Accion"])
        XCTAssertEqual(result.mangas.first?.status, .ongoing)
        XCTAssertFalse(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, searchURL)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(request.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
    func testExactEternalMangasExecutesLatest() async throws {
        let latestURL = "https://api.eternalmangas.org/api/query?page=1&perPage=18&searchTerm=&orderBy=lastChapterAddedAt"
        let body = #"{"posts":[{"id":456,"slug":"otra","postTitle":"Otra","featuredImage":"https://cdn.example/otra.jpg","seriesType":"MANHWA","seriesStatus":"COMPLETED"}],"totalCount":25}"#
        let transport = RoutingTransport(responses: [
            latestURL: response(url: latestURL, contentType: "application/json; charset=utf-8", body: body),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getLatestUpdates(page: 1)
        XCTAssertEqual(result.mangas.count, 1)
        XCTAssertEqual(result.mangas.first?.url, "otra#456")
        XCTAssertEqual(result.mangas.first?.title, "Otra")
        XCTAssertEqual(result.mangas.first?.thumbnailURL, "https://cdn.example/otra.jpg")
        XCTAssertEqual(result.mangas.first?.genres, ["Manhwa"])
        XCTAssertEqual(result.mangas.first?.status, .completed)
        XCTAssertTrue(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, latestURL)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(request.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
    func testExactEternalMangasExecutesPopular() async throws {
        let popularURL = "https://api.eternalmangas.org/api/query?page=1&perPage=18&searchTerm=&orderBy=totalViews"
        let body = #"{"posts":[{"id":123,"slug":"demo","postTitle":"Demo","featuredImage":"https://cdn.example/demo.jpg","seriesType":"MANGA","seriesStatus":"ONGOING","totalChapterCount":12}],"totalCount":1}"#
        let transport = RoutingTransport(responses: [
            popularURL: response(url: popularURL, contentType: "application/json; charset=utf-8", body: body),
        ])
        let source = try PinnedInterpretedSource.eternalmangas1628(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getPopularManga(page: 1)
        XCTAssertEqual(result.mangas.count, 1)
        XCTAssertEqual(result.mangas.first?.url, "demo#123")
        XCTAssertEqual(result.mangas.first?.title, "Demo")
        XCTAssertEqual(result.mangas.first?.thumbnailURL, "https://cdn.example/demo.jpg")
        XCTAssertEqual(result.mangas.first?.genres, ["Manga"])
        XCTAssertEqual(result.mangas.first?.status, .ongoing)
        XCTAssertFalse(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, popularURL)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(request.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://eternalmangas.org/"),
            CompatHTTPHeader(name: "Origin", value: "https://eternalmangas.org"),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
}
