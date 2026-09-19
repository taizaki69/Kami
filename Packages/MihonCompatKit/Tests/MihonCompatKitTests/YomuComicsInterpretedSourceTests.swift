import Foundation
import XCTest
@testable import MihonCompatKit

final class YomuComicsInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case unexpectedRequest
    }

    private actor RejectingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "yomu-comics-construction-probe"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("construction must not execute a request: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private actor SequencedTransport: CompatHTTPTransport {
        nonisolated let sourceID = "yomu-comics-routing-probe"
        private let expectedURL: String
        private let responses: [CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []

        init(expectedURL: String, responses: [CompatHTTPResponse]) {
            self.expectedURL = expectedURL
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard request.url == expectedURL,
                  requests.count <= responses.count else {
                throw RoutingError.unexpectedRequest
            }
            return responses[requests.count - 1]
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "yomu-comics-routing-test"
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
            .appendingPathComponent("Tests/corpus/sssscanlator.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip(
                "corpus APK sssscanlator.apk not present — run scripts/fetch_corpus.sh"
            )
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func response(
        url: String,
        contentType: String,
        body: String
    ) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: contentType)],
            body: Array(body.utf8)
        )
    }

    func testExactYomuComicsConstructsAndExposesInitialFilters() throws {
        let bytes = try corpusAPK()
        let transport = RejectingTransport()
        let source = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: bytes,
            transport: transport
        )

        XCTAssertEqual(source.id, 1_497_838_059_713_668_619)
        XCTAssertEqual(source.name, "Yomu Comics")
        XCTAssertEqual(source.language, "pt-BR")
        XCTAssertEqual(source.baseURL, "https://yomu.com.br")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertTrue(source.supportsFilterFetching)
        XCTAssertTrue(InterpretedExtensionProfileCatalog.supports(
            packageName: "eu.kanade.tachiyomi.extension.pt.sssscanlator",
            versionName: "1.6.59",
            versionCode: 59
        ))
        XCTAssertEqual(
            InterpretedExtensionProfileCatalog.expectedSourceIDs(
                packageName: "eu.kanade.tachiyomi.extension.pt.sssscanlator",
                versionName: "1.6.59",
                versionCode: 59
            ),
            [1_497_838_059_713_668_619]
        )

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 5)
        XCTAssertEqual(filters.map(\.name), [
            "Ordenar por", "Tipo", "Status", "", "Tap 'Reset' to load filters",
        ])
        guard case let .select(sortName, sortValues, sortState) = filters[0],
              case let .select(typeName, typeValues, typeState) = filters[1],
              case let .select(statusName, statusValues, statusState) = filters[2],
              case .separator = filters[3],
              case let .header(loadHint) = filters[4] else {
            return XCTFail("expected the exact initial Yomu Comics select filters")
        }
        XCTAssertEqual(sortName, "Ordenar por")
        XCTAssertEqual(sortValues, ["Mais recentes", "Mais populares", "Melhor nota", "A-Z"])
        XCTAssertEqual(sortState, 0)
        XCTAssertEqual(typeName, "Tipo")
        XCTAssertEqual(typeValues.first, "Todos")
        XCTAssertEqual(typeState, 0)
        XCTAssertEqual(statusName, "Status")
        XCTAssertEqual(statusValues, ["Todos", "Em lançamento", "Completo", "Hiato", "Cancelado"])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(loadHint, "Tap 'Reset' to load filters")
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let invalidPreferences = try InterpretedExtensionPreferences(
            strings: ["unexpected": "value"]
        )
        XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
            packageName: "eu.kanade.tachiyomi.extension.pt.sssscanlator",
            versionName: "1.6.59",
            versionCode: 59,
            apkBytes: bytes,
            transport: transport,
            preferences: invalidPreferences
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .invalidPreferences(profile: "yomu-comics-1.6.59")
            )
        }

        var tampered = bytes
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(try PinnedInterpretedSource.yomuComics1659(
            apkBytes: tampered,
            transport: transport
        )) { error in
            XCTAssertEqual(
                error as? PinnedInterpretedSourceError,
                .apkDigestMismatch(profile: "yomu-comics-1.6.59")
            )
        }
    }

    func testExactYomuComicsRefreshesDynamicGenres() async throws {
        let genresURL = "https://yomu.com.br/api/genres"
        let transport = SequencedTransport(
            expectedURL: genresURL,
            responses: [
                CompatHTTPResponse(finalURL: genresURL, statusCode: 503),
                response(
                    url: genresURL,
                    contentType: "application/json; charset=utf-8",
                    body: #"["Ação","Fantasia"]"#
                ),
            ]
        )
        let source = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let filters = try await source.refreshFilterList()
        XCTAssertEqual(filters.map(\.name), ["Ordenar por", "Tipo", "Status", "Gênero"])
        guard case let .select(name, values, state) = filters[3] else {
            return XCTFail("expected the dynamically loaded Genre select")
        }
        XCTAssertEqual(name, "Gênero")
        XCTAssertEqual(values, ["Todos", "Ação", "Fantasia"])
        XCTAssertEqual(state, 0)
        XCTAssertEqual(source.getFilterList().map(\.name), filters.map(\.name))
        let cachedFilters = try await source.refreshFilterList()
        XCTAssertEqual(
            cachedFilters.map(\.name),
            filters.map(\.name)
        )

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        let expectedHeaders = [
            CompatHTTPHeader(name: "Referer", value: "https://yomu.com.br/"),
            CompatHTTPHeader(name: "Origin", value: "https://yomu.com.br"),
        ]
        XCTAssertTrue(requests.allSatisfy { request in
            request.method == "GET"
                && request.url == genresURL
                && request.body == nil
                && request.cachePolicy == CompatHTTPCachePolicy(maxAgeSeconds: 600)
                && request.headers == expectedHeaders
        })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)

        let unavailable = CompatHTTPResponse(finalURL: genresURL, statusCode: 503)
        let exhaustedTransport = SequencedTransport(
            expectedURL: genresURL,
            responses: [unavailable, unavailable, unavailable]
        )
        let exhaustedSource = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: corpusAPK(),
            transport: exhaustedTransport
        )
        let exhaustedFilters = try await exhaustedSource.refreshFilterList()
        let exhaustedRequests = await exhaustedTransport.snapshot()
        XCTAssertEqual(exhaustedRequests.count, 3)
        let initialNames = [
            "Ordenar por", "Tipo", "Status", "", "Tap 'Reset' to load filters",
        ]
        XCTAssertEqual(exhaustedFilters.map(\.name), initialNames)
        XCTAssertEqual(exhaustedSource.getFilterList().map(\.name), initialNames)
    }

    func testExactYomuComicsExecutesPopularAndFiltersDecoyEntry() async throws {
        let popularURL = "https://yomu.com.br/search?page=2&sort=popular"
        let body = #"0:[{"title":"Demo","slug":"demo","cover":"https://cdn.example/demo.jpg"},{"title":"No Cover","slug":"no-cover","cover":null},{"decoy":true}]"#
        let transport = RoutingTransport(responses: [
            popularURL: response(
                url: popularURL,
                contentType: "text/x-component; charset=utf-8",
                body: body
            ),
        ])
        let source = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let result = try await source.getPopularManga(page: 2)
        XCTAssertEqual(result.mangas.count, 2)
        XCTAssertEqual(result.mangas.map(\.url), ["/obra/demo", "/obra/no-cover"])
        XCTAssertEqual(result.mangas.map(\.title), ["Demo", "No Cover"])
        XCTAssertEqual(result.mangas[0].thumbnailURL, "https://cdn.example/demo.jpg")
        XCTAssertNil(result.mangas[1].thumbnailURL)
        XCTAssertFalse(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, popularURL)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.cachePolicy, CompatHTTPCachePolicy(maxAgeSeconds: 600))
        XCTAssertEqual(request.headers, [
            CompatHTTPHeader(name: "Referer", value: "https://yomu.com.br/"),
            CompatHTTPHeader(name: "Origin", value: "https://yomu.com.br"),
            CompatHTTPHeader(name: "RSC", value: "1"),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testExactYomuComicsExecutesLatestFilteredSearchUpdatePagesAndImage() async throws {
        let genresURL = "https://yomu.com.br/api/genres"
        let latestURL = "https://yomu.com.br/search?page=4&sort=newest"
        let searchURL = "https://yomu.com.br/search?page=3&q=hero&sort=rating&type=MANHWA&status=ONGOING&genre=Fantasia"
        let detailsURL = "https://yomu.com.br/obra/demo"
        let pagesURL = "https://yomu.com.br/ler/demo/1.5"
        let listBody = #"0:[{"title":"Demo","slug":"demo","cover":"https://cdn.example/demo.jpg"}]"#
        let detailsBody = #"0:{"slug":"demo","chapters":[{"id":"chapter-1-5","number":1.5,"title":"","releaseDate":"23/08/2026","releaseAt":"2026-08-23T12:34:56Z"}],"description":"Description","author":"Author","artist":"Artist","coverImage":"https://cdn.example/detail.jpg","status":"ONGOING"}1:{"seriesId":"series-id","title":"Detailed Demo"}2:["$","span","badge-a",{"data-slot":"badge","children":"Action"}]3:["$","span","badge-b",{"data-slot":"badge","children":"Action"}]4:["$","span","badge-c",{"data-slot":"badge","children":"Fantasy"}]"#
        let pagesBody = #"0:{"seriesSlug":"demo","chapter":{"imagens_lista":["https://img.example/1.webp","https://img.example/2.webp"]}}"#
        let transport = RoutingTransport(responses: [
            genresURL: response(
                url: genresURL,
                contentType: "application/json; charset=utf-8",
                body: #"["Ação","Fantasia"]"#
            ),
            latestURL: response(
                url: latestURL,
                contentType: "text/x-component; charset=utf-8",
                body: listBody
            ),
            searchURL: response(
                url: searchURL,
                contentType: "text/x-component; charset=utf-8",
                body: listBody
            ),
            detailsURL: response(
                url: detailsURL,
                contentType: "text/x-component; charset=utf-8",
                body: detailsBody
            ),
            pagesURL: response(
                url: pagesURL,
                contentType: "text/x-component; charset=utf-8",
                body: pagesBody
            ),
        ])
        let source = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: corpusAPK(),
            transport: transport
        )

        var filters = try await source.refreshFilterList()
        guard case let .select(sortName, sortValues, _) = filters[0],
              case let .select(typeName, typeValues, _) = filters[1],
              case let .select(statusName, statusValues, _) = filters[2],
              case let .select(genreName, genreValues, _) = filters[3] else {
            return XCTFail("expected the dynamic Yomu Comics filter schema")
        }
        filters[0] = .select(name: sortName, values: sortValues, state: 2)
        filters[1] = .select(name: typeName, values: typeValues, state: 2)
        filters[2] = .select(name: statusName, values: statusValues, state: 1)
        filters[3] = .select(name: genreName, values: genreValues, state: 2)

        let latest = try await source.getLatestUpdates(page: 4)
        XCTAssertEqual(latest.mangas.map(\.url), ["/obra/demo"])
        XCTAssertFalse(latest.hasNextPage)

        let search = try await source.getSearchManga(
            page: 3,
            query: "hero",
            filters: filters
        )
        XCTAssertEqual(search.mangas.map(\.title), ["Demo"])

        var invalidFilters = filters
        guard case let .select(name, values, state) = invalidFilters[3] else {
            return XCTFail("expected dynamic Genre select")
        }
        invalidFilters[3] = .select(
            name: name,
            values: values + ["Injected"],
            state: state
        )
        do {
            _ = try await source.getSearchManga(
                page: 3,
                query: "hero",
                filters: invalidFilters
            )
            XCTFail("a mutated dynamic filter schema must fail closed")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .invalidInput(operation: "search filters"))
        }

        let update = try await source.getMangaUpdate(
            manga: SMangaCompat(url: "/obra/demo", title: "Old title")
        )
        XCTAssertEqual(update.manga.url, "/obra/demo")
        XCTAssertEqual(update.manga.title, "Detailed Demo")
        XCTAssertEqual(update.manga.thumbnailURL, "https://cdn.example/detail.jpg")
        XCTAssertEqual(update.manga.description, "Description")
        XCTAssertEqual(update.manga.author, "Author")
        XCTAssertEqual(update.manga.artist, "Artist")
        XCTAssertEqual(update.manga.genres, ["Action", "Fantasy"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.ongoing.rawValue)
        XCTAssertEqual(update.chapters.count, 1)
        let chapter = try XCTUnwrap(update.chapters.first)
        XCTAssertEqual(chapter.url, "chapter-1-5")
        XCTAssertEqual(chapter.name, "Capítulo 1.5")
        XCTAssertEqual(chapter.chapterNumber, 1.5)
        XCTAssertEqual(chapter.dateUpload, 1_787_488_496_000)

        let pages = try await source.getPageList(chapter: chapter)
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://img.example/1.webp", "https://img.example/2.webp",
        ])
        let generatedImageRequest = await source.getImageRequest(page: pages[0])
        let imageRequest = try XCTUnwrap(generatedImageRequest)
        XCTAssertEqual(imageRequest.url, "https://img.example/1.webp")
        XCTAssertEqual(imageRequest.headers, [
            "Referer": "https://yomu.com.br/",
            "Origin": "https://yomu.com.br",
        ])
        XCTAssertNil(imageRequest.sourceExecutionID)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            genresURL, latestURL, searchURL, detailsURL, pagesURL,
        ])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        XCTAssertTrue(requests.allSatisfy {
            $0.cachePolicy == CompatHTTPCachePolicy(maxAgeSeconds: 600)
        })
        let baseHeaders = [
            CompatHTTPHeader(name: "Referer", value: "https://yomu.com.br/"),
            CompatHTTPHeader(name: "Origin", value: "https://yomu.com.br"),
        ]
        XCTAssertEqual(requests.first?.headers, baseHeaders)
        let rscHeaders = baseHeaders + [CompatHTTPHeader(name: "RSC", value: "1")]
        XCTAssertTrue(requests.dropFirst().allSatisfy {
            $0.headers == rscHeaders
        })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testExactYomuComicsCoversURLSearchAndListingBoundaries() async throws {
        let detailsURL = "https://yomu.com.br/obra/demo"
        let fullPageURL = "https://yomu.com.br/search?page=5&sort=popular"
        let majorityDecoyURL = "https://yomu.com.br/search?page=6&sort=popular"
        let orderedNestedURL = "https://yomu.com.br/search?page=7&sort=popular"
        let reversedNestedURL = "https://yomu.com.br/search?page=8&sort=popular"
        let nestedEntries = (0..<16).map { index in
            "\"slot-\(index)\":[{\"title\":\"Nested \(index)\",\"slug\":\"nested-\(index)\"}]"
        }
        let detailsBody = #"0:{"slug":"demo","chapters":[]}1:{"seriesId":"series-id","title":"URL Demo"}"#
        let entries = (0..<30).map { index in
            "{\"title\":\"Title \(index)\",\"slug\":\"slug-\(index)\"}"
        }.joined(separator: ",")
        let transport = RoutingTransport(responses: [
            detailsURL: response(
                url: detailsURL,
                contentType: "text/x-component; charset=utf-8",
                body: detailsBody
            ),
            fullPageURL: response(
                url: fullPageURL,
                contentType: "text/x-component; charset=utf-8",
                body: "0:[\(entries)]"
            ),
            majorityDecoyURL: response(
                url: majorityDecoyURL,
                contentType: "text/x-component; charset=utf-8",
                body: #"0:[{"title":"Only","slug":"one"},{"decoy":true},{"alsoDecoy":true}]"#
            ),
            orderedNestedURL: response(
                url: orderedNestedURL,
                contentType: "text/x-component; charset=utf-8",
                body: "0:{\(nestedEntries.joined(separator: ","))}"
            ),
            reversedNestedURL: response(
                url: reversedNestedURL,
                contentType: "text/x-component; charset=utf-8",
                body: "0:{\(nestedEntries.reversed().joined(separator: ","))}"
            ),
        ])
        let source = try PinnedInterpretedSource.yomuComics1659(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let normalized = try await source.getSearchManga(
            page: 1,
            query: "https://outside.example/ler/demo/1.5",
            filters: []
        )
        XCTAssertEqual(normalized.mangas.map(\.url), ["/obra/demo"])
        XCTAssertEqual(normalized.mangas.map(\.title), ["URL Demo"])
        XCTAssertFalse(normalized.hasNextPage)

        let invalidPath = try await source.getSearchManga(
            page: 1,
            query: "https://outside.example/not-a-series/demo",
            filters: []
        )
        XCTAssertTrue(invalidPath.mangas.isEmpty)
        XCTAssertFalse(invalidPath.hasNextPage)

        let fullPage = try await source.getPopularManga(page: 5)
        XCTAssertEqual(fullPage.mangas.count, 30)
        XCTAssertTrue(fullPage.hasNextPage)

        do {
            _ = try await source.getPopularManga(page: 6)
            XCTFail("a majority-decoy list must not satisfy the strict-majority rule")
        } catch let error as DEXThrowable {
            XCTAssertTrue(error.description.contains("Não foi possível ler a lista de obras"))
        }

        // Yomu recursively selects the first matching nested listing in an RSC
        // object. Reversing source member order must reverse which listing wins.
        let orderedNested = try await source.getPopularManga(page: 7)
        let reversedNested = try await source.getPopularManga(page: 8)
        XCTAssertEqual(orderedNested.mangas.map(\.title), ["Nested 0"])
        XCTAssertEqual(reversedNested.mangas.map(\.title), ["Nested 15"])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            detailsURL, fullPageURL, majorityDecoyURL, orderedNestedURL, reversedNestedURL,
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }
}
