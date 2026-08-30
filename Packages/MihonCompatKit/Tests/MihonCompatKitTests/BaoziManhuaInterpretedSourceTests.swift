import Foundation
import XCTest
@testable import MihonCompatKit

final class BaoziManhuaInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(String)
    }

    private actor NoNetworkTransport: CompatHTTPTransport {
        nonisolated let sourceID = "baozi-manhua-adapter-test"
        private var requests: [CompatHTTPRequest] = []

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            XCTFail("Baozi construction must not perform network I/O")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "baozi-manhua-routing-test"

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

    private actor SingleExchangeRoutingTransport: CompatHTTPSingleExchangeTransport {
        nonisolated let sourceID = "baozi-manhua-single-exchange-test"

        private let responses: [String: CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []
        private var automaticExecutions = 0

        init(responses: [String: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            automaticExecutions += 1
            throw RoutingError.missingResponse("automatic:" + request.url)
        }

        func executeSingleExchange(
            _ request: CompatHTTPRequest
        ) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard let response = responses[request.url] else {
                throw RoutingError.missingResponse(request.url)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
        func automaticExecutionCount() -> Int { automaticExecutions }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/baozimanhua.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK baozimanhua.apk not present — run scripts/fetch_corpus.sh")
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
        let popularURL = "https://cn.baozimh.com/classify?page=1"
        let latestURL = "https://cn.baozimh.com/list/new"
        let searchURL = "https://cn.baozimh.com/search?q=hero"
        let detailsURL = "https://cn.baozimh.com/comic/baozi-hero"
        let pagesURL = "https://cn.baozimh.com/comic/chapter/baozi-hero/1_1.html"

        let popularHTML = """
        <div class="comics-card">
          <a class="comics-card__poster" href="/comic/popular-hero">
            <img data-src="/covers/popular-hero.jpg">
          </a>
          <div class="comics-card__title">Popular Hero</div>
        </div>
        """
        let latestHTML = """
        <div class="comics-card">
          <a class="comics-card__poster" href="/comic/latest-hero">
            <img data-src="/covers/latest-hero.jpg">
          </a>
          <div class="comics-card__title">Latest Hero</div>
        </div>
        """
        let searchHTML = """
        <div class="comics-card">
          <a class="comics-card__poster" href="/comic/search-hero">
            <img data-src="/covers/search-hero.jpg">
          </a>
          <div class="comics-card__title">Search Hero</div>
        </div>
        """
        let detailsHTML = """
        <h1 class="comics-detail__title">Baozi Hero</h1>
        <meta name="og:image" content="https://images.example/baozi-hero.jpg">
        <h2 class="comics-detail__author">Baozi Writer</h2>
        <p class="comics-detail__desc">A measured Baozi work.</p>
        <div class="tag-list"><span class="tag">连载中</span></div>
        <em>(2026年08月23日 更新)</em>
        <div class="comics-chapters">
          <a href="/comic/chapter/baozi-hero/1_1.html">第1话</a>
        </div>
        <div class="comics-chapters">
          <a href="/comic/chapter/baozi-hero/1_2.html">第2话</a>
        </div>
        """
        let pagesHTML = """
        <div class="comic-contain">
          <img data-src="/pages/baozi-hero/001.jpg">
          <img src="https://images.example/baozi-hero/002.jpg">
        </div>
        """

        return [
            popularURL: response(url: popularURL, body: popularHTML),
            latestURL: response(url: latestURL, body: latestHTML),
            searchURL: response(url: searchURL, body: searchHTML),
            detailsURL: response(url: detailsURL, body: detailsHTML),
            pagesURL: response(url: pagesURL, body: pagesHTML),
        ]
    }

    func testExactBaoziProfileConstructsWithoutNetworkIO() async throws {
        let transport = NoNetworkTransport()
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )

        XCTAssertEqual(source.id, 5_724_751_873_601_868_259)
        XCTAssertEqual(source.name, "包子漫画")
        XCTAssertEqual(source.language, "zh")
        XCTAssertEqual(source.baseURL, "https://cn.baozimh.com")
        XCTAssertTrue(source.supportsLatest)
        let imageRequest = await source.getImageRequest(page: PageCompat(
            index: 0,
            imageURL: "https://static.baozicdn.com/chapter/001.jpg"
        ))
        XCTAssertEqual(
            imageRequest?.url,
            "https://static.baozimh.com/chapter/001.jpg",
            source.compatibilityReport().renderedText()
        )
        XCTAssertNil(imageRequest?.sourceExecutionID)
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testBaoziReaderImageRetainsTagsAndRunsConfiguredClientWhenBannerDisabled() async throws {
        let imageURL = "https://static.baozimh.com/chapter/001.jpg"
        let transport = RoutingTransport(responses: [
            imageURL: CompatHTTPResponse(
                finalURL: imageURL,
                statusCode: 302,
                headers: [
                    CompatHTTPHeader(
                        name: "Location",
                        value: "https://redirect.example/chapter/002.jpg"
                    ),
                    CompatHTTPHeader(name: "X-Kami-Fixture", value: "preserved"),
                ],
                body: [1, 2, 3]
            ),
        ])
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport,
            preferences: try InterpretedExtensionPreferences(
                strings: ["BAOZI_BANNER": "0"]
            )
        )

        let generated = await source.getImageRequest(page: PageCompat(
            index: 0,
            imageURL: "https://static.baozicdn.com/chapter/001.jpg"
        ))
        let imageRequest = try XCTUnwrap(generated)
        XCTAssertNotNil(imageRequest.sourceExecutionID)
        let executed = try await imageRequest.executeSourceRequest()
        let response = try XCTUnwrap(executed)

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.body, [1, 2, 3])
        XCTAssertEqual(
            response.headers.first {
                $0.name.caseInsensitiveCompare("Location") == .orderedSame
            }?.value,
            "https://cn.baozimh.com/chapter/002.jpg"
        )
        XCTAssertEqual(
            response.headers.first { $0.name == "X-Kami-Fixture" }?.value,
            "preserved"
        )
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, imageURL)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testBaoziReaderImageRewritesAndFollowsAnObservableRedirect() async throws {
        let imageURL = "https://static.baozimh.com/chapter/001.jpg"
        let rewrittenURL = "https://cn.baozimh.com/chapter/002.jpg"
        let transport = SingleExchangeRoutingTransport(responses: [
            imageURL: CompatHTTPResponse(
                finalURL: imageURL,
                statusCode: 302,
                headers: [
                    CompatHTTPHeader(
                        name: "Location",
                        value: "https://redirect.example/chapter/002.jpg"
                    ),
                    CompatHTTPHeader(name: "X-Kami-Fixture", value: "first-exchange"),
                ],
                body: [1]
            ),
            rewrittenURL: CompatHTTPResponse(
                finalURL: rewrittenURL,
                statusCode: 200,
                headers: [CompatHTTPHeader(name: "Content-Type", value: "image/jpeg")],
                body: [0xff, 0xd8, 0xff, 0xd9]
            ),
        ])
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport,
            preferences: try InterpretedExtensionPreferences(
                strings: ["BAOZI_BANNER": "0"]
            )
        )

        let generated = await source.getImageRequest(page: PageCompat(
            index: 0,
            imageURL: "https://static.baozicdn.com/chapter/001.jpg"
        ))
        let imageRequest = try XCTUnwrap(generated)
        let executed = try await imageRequest.executeSourceRequest()
        let response = try XCTUnwrap(executed)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.finalURL, rewrittenURL)
        XCTAssertEqual(response.body, [0xff, 0xd8, 0xff, 0xd9])
        let requests = await transport.snapshot()
        let automaticExecutions = await transport.automaticExecutionCount()
        XCTAssertEqual(requests.map(\.url), [imageURL, rewrittenURL])
        XCTAssertEqual(automaticExecutions, 0)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testBaoziRejectsInvalidPreferencesBeforeAnyTransport() async throws {
        let apk = try corpusAPK()
        let invalidPreferences: [InterpretedExtensionPreferences] = [
            try InterpretedExtensionPreferences(strings: ["BAOZI_BANNER": "9"]),
            try InterpretedExtensionPreferences(booleans: ["UNSUPPORTED": true]),
        ]

        for preferences in invalidPreferences {
            let transport = RoutingTransport(responses: [:])
            XCTAssertThrowsError(try PinnedInterpretedSource.baoziManhua1629(
                apkBytes: apk,
                transport: transport,
                preferences: preferences
            )) { error in
                XCTAssertEqual(
                    error as? PinnedInterpretedSourceError,
                    .invalidPreferences(profile: "baozi-manhua-1.6.29")
                )
            }
            let requests = await transport.snapshot()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testInterpretedPreferencesEnforceScalarBoundsAndUniqueTypes() throws {
        let tooManyValues = Dictionary(
            uniqueKeysWithValues: (0..<65).map { ("key-\($0)", "value") }
        )
        XCTAssertThrowsError(try InterpretedExtensionPreferences(strings: tooManyValues)) {
            XCTAssertEqual(
                $0 as? InterpretedExtensionPreferences.ValidationError,
                .tooManyValues
            )
        }
        XCTAssertThrowsError(try InterpretedExtensionPreferences(strings: ["": "value"])) {
            XCTAssertEqual(
                $0 as? InterpretedExtensionPreferences.ValidationError,
                .invalidKey
            )
        }
        XCTAssertThrowsError(try InterpretedExtensionPreferences(
            strings: ["same": "value"],
            booleans: ["same": true]
        )) {
            XCTAssertEqual(
                $0 as? InterpretedExtensionPreferences.ValidationError,
                .duplicateKey
            )
        }
        XCTAssertThrowsError(try InterpretedExtensionPreferences(
            strings: ["key": String(repeating: "x", count: 4_097)]
        )) {
            XCTAssertEqual(
                $0 as? InterpretedExtensionPreferences.ValidationError,
                .stringValueTooLarge
            )
        }
    }

    func testBaoziExposesExactFilterSchema() async throws {
        let transport = NoNetworkTransport()
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 5)
        guard case let .header(header) = filters[0] else {
            return XCTFail("expected Baozi filter header")
        }
        XCTAssertEqual(header, "注意：不影響按標題搜索")

        guard case let .select(tagName, tagValues, tagState) = filters[1],
              case let .select(regionName, regionValues, regionState) = filters[2],
              case let .select(statusName, statusValues, statusState) = filters[3],
              case let .select(startName, startValues, startState) = filters[4] else {
            return XCTFail("expected four Baozi select filters")
        }
        XCTAssertEqual(tagName, "标签")
        XCTAssertEqual(tagValues, [
            "全部", "都市", "冒险", "热血", "恋爱", "耽美", "武侠", "格斗", "科幻",
            "魔幻", "推理", "玄幻", "日常", "生活", "搞笑", "校园", "奇幻", "萌系",
            "穿越", "后宫", "战争", "历史", "剧情", "同人", "竞技", "励志", "治愈",
            "机甲", "纯爱", "美食", "恶搞", "虐心", "动作", "惊险", "唯美", "复仇",
            "脑洞", "宫斗", "运动", "灵异", "古风", "权谋", "节操", "明星", "暗黑",
            "社会", "音乐舞蹈", "东方", "AA", "悬疑", "轻小说", "霸总", "萝莉", "战斗",
            "惊悚", "百合", "大女主", "幻想", "少女", "少年", "性转", "重生", "韩漫", "其它",
        ])
        XCTAssertEqual(tagState, 0)
        XCTAssertEqual(regionName, "地区")
        XCTAssertEqual(regionValues, ["全部", "国漫", "日本", "韩国", "欧美"])
        XCTAssertEqual(regionState, 0)
        XCTAssertEqual(statusName, "进度")
        XCTAssertEqual(statusValues, ["全部", "连载中", "已完结"])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(startName, "标题开头")
        XCTAssertEqual(startValues, [
            "全部", "ABCD", "EFGH", "IJKL", "MNOP", "QRST", "UVW", "XYZ", "0-9",
        ])
        XCTAssertEqual(startState, 0)
    }

    func testBaoziRejectsMutatedFilterSchemaBeforeTransport() async throws {
        let transport = RoutingTransport(responses: [:])
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )
        var mutated = source.getFilterList()
        guard case let .select(name, values, state) = mutated[1] else {
            return XCTFail("expected Baozi tag filter")
        }
        mutated[1] = .select(name: name, values: values + ["Injected"], state: state)

        do {
            _ = try await source.getSearchManga(
                page: 1,
                query: "hero",
                filters: mutated
            )
            XCTFail("mutated Baozi filter options must fail closed")
        } catch let error as PinnedInterpretedSourceError {
            XCTAssertEqual(error, .invalidInput(operation: "search filters"))
        }
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testBaoziAppliesNonDefaultFilterStateToDEXRequest() async throws {
        let transport = RoutingTransport(responses: [:])
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )
        let defaults = source.getFilterList()
        var selected = defaults
        guard case let .select(name, values, _) = selected[1] else {
            return XCTFail("expected Baozi tag filter")
        }
        selected[1] = .select(name: name, values: values, state: 1)

        for filters in [defaults, selected] {
            do {
                _ = try await source.getSearchManga(page: 2, query: "", filters: filters)
                XCTFail("empty routing transport must reject the generated request")
            } catch {
                // The compatibility bridge maps the transport sentinel to a
                // DEX IOException. Request assertions below distinguish that
                // expected terminal failure from a pre-transport filter gap.
            }
        }

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }
        XCTAssertNotEqual(requests[0].url, requests[1].url)
        XCTAssertTrue(requests.allSatisfy { $0.url.contains("/classify") })
    }

    func testCancelledBaoziImageRequestReturnsNilWithoutCompatibilityFinding() async throws {
        let transport = NoNetworkTransport()
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )
        let task = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await source.getImageRequest(page: PageCompat(
                index: 0,
                imageURL: "https://static.baozicdn.com/chapter/cancelled.jpg"
            ))
        }
        task.cancel()

        let result = await task.value
        let requests = await transport.snapshot()
        XCTAssertNil(result)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testBaoziExecutesPopularLatestTextSearchDetailsChaptersAndPages() async throws {
        let popularURL = "https://cn.baozimh.com/classify?page=1"
        let latestURL = "https://cn.baozimh.com/list/new"
        let searchURL = "https://cn.baozimh.com/search?q=hero"
        let detailsURL = "https://cn.baozimh.com/comic/baozi-hero"
        let pagesURL = "https://cn.baozimh.com/comic/chapter/baozi-hero/1_1.html"
        let transport = RoutingTransport(responses: routes())
        let source = try PinnedInterpretedSource.baoziManhua1629(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let popular: MangasPageCompat
        do {
            popular = try await source.getPopularManga(page: 1)
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "popular failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(popular.mangas.count, 1)
        XCTAssertEqual(popular.mangas[0].url, "/comic/popular-hero")
        XCTAssertEqual(popular.mangas[0].title, "Popular Hero")
        XCTAssertEqual(
            popular.mangas[0].thumbnailURL,
            "https://cn.baozimh.com/covers/popular-hero.jpg"
        )
        XCTAssertFalse(popular.hasNextPage)

        let latest: MangasPageCompat
        do {
            latest = try await source.getLatestUpdates(page: 1)
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "latest failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(latest.mangas.count, 1)
        XCTAssertEqual(latest.mangas[0].url, "/comic/latest-hero")
        XCTAssertEqual(latest.mangas[0].title, "Latest Hero")
        XCTAssertFalse(latest.hasNextPage)

        let search: MangasPageCompat
        do {
            search = try await source.getSearchManga(page: 1, query: "hero", filters: [])
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "search failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(search.mangas.count, 1)
        XCTAssertEqual(search.mangas[0].url, "/comic/search-hero")
        XCTAssertEqual(search.mangas[0].title, "Search Hero")
        XCTAssertFalse(search.hasNextPage)

        let inputManga = SMangaCompat(
            url: "/comic/baozi-hero",
            title: "Uninitialized Baozi Hero"
        )
        let details: SMangaCompat
        do {
            details = try await source.getMangaDetails(manga: inputManga)
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "details failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(details.url, "/comic/baozi-hero")
        XCTAssertEqual(details.title, "Baozi Hero")
        XCTAssertEqual(details.thumbnailURL, "https://images.example/baozi-hero.jpg")
        XCTAssertEqual(details.author, "Baozi Writer")
        XCTAssertEqual(details.description, "A measured Baozi work.")
        XCTAssertEqual(details.genres, [])
        XCTAssertEqual(details.status.rawValue, MangaStatus.ongoing.rawValue)

        let chapters: [SChapterCompat]
        do {
            chapters = try await source.getChapterList(manga: inputManga)
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "chapters failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].url, "/comic/chapter/baozi-hero/1_1.html")
        XCTAssertEqual(chapters[0].name, "第1话")
        XCTAssertEqual(chapters[0].chapterNumber, -1)
        XCTAssertGreaterThan(chapters[0].dateUpload, 0)
        XCTAssertEqual(chapters[1].url, "/comic/chapter/baozi-hero/1_2.html")
        XCTAssertEqual(chapters[1].name, "第2话")

        let pages: [PageCompat]
        do {
            pages = try await source.getPageList(chapter: chapters[0])
        } catch {
            let attempted = await transport.snapshot()
            XCTFail(
                "pages failed after \(attempted.map(\.url)): \(error)\n"
                    + source.compatibilityReport().renderedText()
            )
            return
        }
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://cn.baozimh.com/pages/baozi-hero/001.jpg",
            "https://images.example/baozi-hero/002.jpg",
        ])

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.url), [
            popularURL,
            latestURL,
            searchURL,
            detailsURL,
            detailsURL,
            pagesURL,
        ])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
    }
}
