import Foundation
import XCTest
@testable import MihonCompatKit

final class MangaMelonInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(String)
        case malformedFormBody
    }

    private actor RecordingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangamelon-adapter-test"

        private var requests: [CompatHTTPRequest] = []

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return CompatHTTPResponse(
                finalURL: request.url,
                statusCode: 200,
                headers: [CompatHTTPHeader(
                    name: "Content-Type",
                    value: "application/json; charset=utf-8"
                )],
                body: Array(#"{"list":[],"total":0}"#.utf8)
            )
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangamelon-routing-test"

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
            .appendingPathComponent("Tests/corpus/mangamelon.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK mangamelon.apk not present — run scripts/fetch_corpus.sh")
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

    private func decodedFormJSON(_ request: CompatHTTPRequest) throws -> String {
        guard case let .form(fields) = request.body,
              fields.count == 2,
              fields[0].name == "data",
              fields[1] == CompatHTTPFormField(name: "sessionid", value: ""),
              let bytes = Data(base64Encoded: fields[0].value),
              let json = String(data: bytes, encoding: .utf8) else {
            throw RoutingError.malformedFormBody
        }
        return json
    }

    func testCurrentMangaMelonProfileExposesAndAppliesStaticFilters() async throws {
        let transport = RecordingTransport()
        let source = try PinnedInterpretedSource.mangaMelon161(
            apkBytes: corpusAPK(),
            transport: transport
        )

        XCTAssertEqual(source.id, 7_505_916_148_185_744_347)
        XCTAssertEqual(source.name, "MangaMelon")
        XCTAssertEqual(source.language, "en")
        XCTAssertEqual(source.baseURL, "https://mangamelon.com")
        XCTAssertTrue(source.supportsLatest)

        let defaults = source.getFilterList()
        XCTAssertEqual(defaults.count, 2)
        guard case let .sort(sortName, sortValues, sortState) = defaults[0] else {
            return XCTFail("expected Sort filter")
        }
        XCTAssertEqual(sortName, "Sort")
        XCTAssertEqual(sortValues, ["Latest", "Hot", "Top Rated", "New"])
        XCTAssertNil(sortState)

        guard case let .select(genreName, genreValues, genreState) = defaults[1] else {
            return XCTFail("expected Genre filter")
        }
        XCTAssertEqual(genreName, "Genre")
        XCTAssertEqual(genreValues.prefix(5), ["All", "Action", "Adult", "Adventure", "Comedy"])
        XCTAssertEqual(genreState, 0)

        let selected: [SourceFilter] = [
            .sort(
                name: sortName,
                values: sortValues,
                state: .init(index: 2, ascending: false)
            ),
            .select(name: genreName, values: genreValues, state: 4),
        ]
        let result = try await source.getSearchManga(
            page: 2,
            query: "hero",
            filters: selected
        )
        XCTAssertTrue(result.mangas.isEmpty)
        XCTAssertFalse(result.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, "https://api.mangamelon.com/api/manga/list")
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].body, .form(fields: [
            CompatHTTPFormField(
                name: "data",
                value: "eyJzZWFyY2giOiJoZXJvIiwiZ2VucmUiOiJDb21lZHkiLCJsYW5nIjoiZW4iLCJzb3J0IjoicmF0aW5nIiwiaW5jbHVkZU5zZnciOnRydWUsImxpbWl0IjozNiwic2tpcCI6MzZ9"
            ),
            CompatHTTPFormField(name: "sessionid", value: ""),
        ]))
    }

    func testCurrentMangaMelonProfileRejectsMutatedFilterSchemaBeforeTransport() async throws {
        let transport = RecordingTransport()
        let source = try PinnedInterpretedSource.mangaMelon161(
            apkBytes: corpusAPK(),
            transport: transport
        )
        let defaults = source.getFilterList()
        guard case let .sort(sortName, sortValues, _) = defaults[0],
              case let .select(genreName, genreValues, _) = defaults[1] else {
            return XCTFail("expected MangaMelon filter schema")
        }
        let mutated: [SourceFilter] = [
            .sort(name: sortName, values: sortValues, state: nil),
            .select(name: genreName, values: genreValues + ["Injected"], state: 0),
        ]

        do {
            _ = try await source.getSearchManga(page: 1, query: "hero", filters: mutated)
            XCTFail("mutated filter options must fail closed")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .invalidInput(operation: "search filters"))
        }
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCurrentMangaMelonProfileExecutesEveryCoreSourceOperation() async throws {
        let listURL = "https://api.mangamelon.com/api/manga/list"
        let detailsURL = "https://api.mangamelon.com/api/manga/get"
        let chaptersURL = "https://api.mangamelon.com/api/chapter/list"
        let pagesURL = "https://api.mangamelon.com/api/chapter/get"
        let listingJSON = #"{"list":[{"id":"hero","title":"Hero","cover":"https://images.example/hero.jpg","desc":"A measured hero.","status":"ongoing","authors":"Writer","genres":["Action","Adventure"]}],"total":100}"#
        let detailsJSON = #"{"manga":{"id":"hero","title":"Hero","cover":"https://images.example/hero.jpg","desc":"A measured hero.","status":"ongoing","authors":"Writer","genres":["Action","Adventure"]}}"#
        let chaptersJSON = #"{"chapters":[{"id":"chapter-7","title":"Chapter Seven","seq":7,"updated":"2026-08-23T12:34:56Z","pages":[] }]}"#
        let pagesJSON = #"{"chapter":{"id":"chapter-7","title":"Chapter Seven","seq":7,"updated":null,"pages":[{"url":"https://images.example/page-2.jpg","seq":2},{"url":"https://images.example/page-1.jpg","seq":1}]}}"#
        let transport = RoutingTransport(responses: [
            listURL: response(url: listURL, json: listingJSON),
            detailsURL: response(url: detailsURL, json: detailsJSON),
            chaptersURL: response(url: chaptersURL, json: chaptersJSON),
            pagesURL: response(url: pagesURL, json: pagesJSON),
        ])
        let source = try PinnedInterpretedSource.mangaMelon161(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.first?.title, "Hero")
        XCTAssertEqual(popular.mangas.first?.url, "hero")
        XCTAssertTrue(popular.hasNextPage)

        let latest = try await source.getLatestUpdates(page: 2)
        XCTAssertEqual(latest.mangas.first?.title, "Hero")
        XCTAssertTrue(latest.hasNextPage)

        let defaults = source.getFilterList()
        guard case let .sort(sortName, sortValues, _) = defaults[0],
              case let .select(genreName, genreValues, _) = defaults[1] else {
            return XCTFail("expected MangaMelon filter schema")
        }
        let search = try await source.getSearchManga(page: 3, query: "hero", filters: [
            .sort(
                name: sortName,
                values: sortValues,
                state: .init(index: 2, ascending: false)
            ),
            .select(name: genreName, values: genreValues, state: 4),
        ])
        XCTAssertEqual(search.mangas.first?.url, "hero")
        XCTAssertTrue(search.hasNextPage)

        let update = try await source.getMangaUpdate(manga: SMangaCompat(
            url: "hero",
            title: "Old title"
        ))
        XCTAssertEqual(update.manga.title, "Hero")
        XCTAssertEqual(update.manga.description, "A measured hero.")
        XCTAssertEqual(update.manga.author, "Writer")
        XCTAssertEqual(update.manga.genres, ["Action", "Adventure"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.ongoing.rawValue)
        XCTAssertEqual(update.chapters.count, 1)
        XCTAssertEqual(update.chapters[0].url, "chapter-7")
        XCTAssertEqual(update.chapters[0].name, "Chapter Seven")
        XCTAssertGreaterThan(update.chapters[0].dateUpload, 0)

        let pages = try await source.getPageList(chapter: update.chapters[0])
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://images.example/page-1.jpg",
            "https://images.example/page-2.jpg",
        ])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.method == "POST" })
        let listRequests = requests.filter { $0.url == listURL }
        XCTAssertEqual(try listRequests.map(decodedFormJSON), [
            #"{"search":"","genre":"","lang":"en","sort":"popular","includeNsfw":true,"limit":36,"skip":0}"#,
            #"{"search":"","genre":"","lang":"en","sort":"latest","includeNsfw":true,"limit":36,"skip":36}"#,
            #"{"search":"hero","genre":"Comedy","lang":"en","sort":"rating","includeNsfw":true,"limit":36,"skip":72}"#,
        ])
        XCTAssertEqual(
            try requests.first { $0.url == detailsURL }.map(decodedFormJSON),
            #"{"target":"hero","withReviews":false}"#
        )
        XCTAssertEqual(
            try requests.first { $0.url == chaptersURL }.map(decodedFormJSON),
            #"{"target":"hero","status":0,"limit":1000,"skip":0,"pending":"","force":true}"#
        )
        XCTAssertEqual(
            try requests.first { $0.url == pagesURL }.map(decodedFormJSON),
            #"{"target":"chapter-7","all":true}"#
        )
    }
}
