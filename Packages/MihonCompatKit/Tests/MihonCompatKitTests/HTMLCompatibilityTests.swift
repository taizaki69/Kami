import XCTest
@testable import MihonCompatKit

final class HTMLCompatibilityTests: XCTestCase {
    func testParserSupportsBatCaveSelectorsTextAndAbsoluteURLs() throws {
        let html = """
        <div id="dle-content">
          <article class="readed">
            <div class="readed__title">
              <a href="/comic/alpha?from=popular#top">Alpha &amp; Omega</a>
            </div>
            <img data-src="/uploads/alpha.jpg">
          </article>
        </div>
        <div class="pagination__pages"><span>1</span><a href="page/2/">2</a></div>
        """
        let context = try CompatHTMLParser.parse(
            html,
            baseURL: "https://batcave.biz/comix/",
            policy: .init()
        )

        let entries = try context.select(context.document, query: "#dle-content > .readed")
        let entry = try XCTUnwrap(entries.first)
        let anchor = try XCTUnwrap(
            try context.select(entry, query: ".readed__title > a").first
        )
        let image = try XCTUnwrap(try context.select(entry, query: "img").first)
        let pagination = try XCTUnwrap(
            try context.select(context.document, query: "div.pagination__pages").first
        )

        XCTAssertEqual(anchor.ownText(), "Alpha & Omega")
        XCTAssertEqual(
            try anchor.absUrl("href"),
            "https://batcave.biz/comic/alpha?from=popular#top"
        )
        XCTAssertEqual(
            try image.absUrl("data-src"),
            "https://batcave.biz/uploads/alpha.jpg"
        )
        XCTAssertEqual(pagination.children().array().last?.tagName(), "a")
    }

    func testRelativeDirectChildSelectorsMatchModernJsoupSemantics() throws {
        let html = """
        <ul class="page__list">
          <li id="direct"><div>Publisher</div><a>Direct Value</a></li>
          <li id="nested"><section><div>Publisher</div></section><a>Nested Value</a></li>
          <li id="other"><div>Writer</div><a>Other Value</a></li>
        </ul>
        """
        let context = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/details",
            policy: .init()
        )

        let matches = try context.select(
            context.document,
            query: ".page__list > li:has(> div:contains(Publisher))"
        )
        XCTAssertEqual(matches.map { $0.id() }, ["direct"])

        let anchor = try XCTUnwrap(
            try context.select(try XCTUnwrap(matches.first), query: "> a").first
        )
        XCTAssertEqual(anchor.ownText(), "Direct Value")
    }

    func testContainsDataMatchesScriptDataWithJsoupSemantics() throws {
        let html = """
        <script>window.__DATA__ = {"id": 42};</script>
        <script>window.other = true;</script>
        """
        let context = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/details",
            policy: .init()
        )

        let scripts = try context.select(
            context.document,
            query: "script:containsData(WINDOW.__data__)"
        )
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].data().contains("{\"id\": 42}"))
    }

    func testParserRejectsInvalidBaseURLAndOversizedInput() {
        assertHTMLFailure(.invalidBaseURL) {
            try CompatHTMLParser.parse(
                "<p>safe</p>",
                baseURL: "file:///private/data",
                policy: .init()
            )
        }

        assertHTMLFailure(.inputTooLarge(limit: 8)) {
            try CompatHTMLParser.parse(
                "<p>too large</p>",
                baseURL: "https://example.test/",
                policy: .init(maximumInputBytes: 8)
            )
        }
    }

    func testParserEnforcesDOMNodeDepthAndAttributeLimits() {
        assertHTMLFailure(.tooManyNodes(limit: 1)) {
            try CompatHTMLParser.parse(
                "<p>one node is already too many after the document root</p>",
                baseURL: "https://example.test/",
                policy: .init(maximumNodes: 1)
            )
        }

        assertHTMLFailure(.nestingTooDeep(limit: 1)) {
            try CompatHTMLParser.parse(
                "<div><span>nested</span></div>",
                baseURL: "https://example.test/",
                policy: .init(maximumDepth: 1)
            )
        }

        assertHTMLFailure(.tooManyAttributesOnElement(limit: 1)) {
            try CompatHTMLParser.parse(
                "<div data-a='1' data-b='2'></div>",
                baseURL: "https://example.test/",
                policy: .init(maximumAttributesPerElement: 1)
            )
        }

        assertHTMLFailure(.tooManyAttributes(limit: 1)) {
            try CompatHTMLParser.parse(
                "<div data-a='1'></div><span data-b='2'></span>",
                baseURL: "https://example.test/",
                policy: .init(maximumAttributes: 1)
            )
        }
    }

    func testSelectorLimitsCoverLengthResultsAndSyntax() throws {
        let html = "<main><p class='one'>1</p><p class='two'>2</p></main>"

        let shortSelectorContext = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/",
            policy: .init(maximumSelectorBytes: 3)
        )
        assertHTMLFailure(.selectorTooLarge(limit: 3)) {
            try shortSelectorContext.select(shortSelectorContext.document, query: "p.one")
        }

        let resultContext = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/",
            policy: .init(maximumSelectorResults: 1)
        )
        assertHTMLFailure(.tooManySelectorResults(limit: 1)) {
            try resultContext.select(resultContext.document, query: "p")
        }

        let syntaxContext = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/",
            policy: .init()
        )
        assertHTMLFailure(.invalidSelector) {
            try syntaxContext.select(syntaxContext.document, query: ":not(")
        }
    }

    func testSelectorWorkBudgetIsCumulativeAndExtractedStringsAreBounded() throws {
        let html = "<main><p>one</p><p>two</p></main>"
        let baseline = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/",
            policy: .init()
        )
        let oneQueryCost = baseline.nodeCount
        let context = try CompatHTMLParser.parse(
            html,
            baseURL: "https://example.test/",
            policy: .init(
                maximumSelectorWork: oneQueryCost,
                maximumExtractedStringBytes: 4
            )
        )

        XCTAssertEqual(try context.select(context.document, query: "p").count, 2)
        assertHTMLFailure(.selectorBudgetExceeded(limit: oneQueryCost)) {
            try context.select(context.document, query: "p")
        }
        assertHTMLFailure(.extractedStringTooLarge(limit: 4)) {
            try context.boundedString("12345")
        }
    }

    private func assertHTMLFailure<T>(
        _ expected: CompatHTMLError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CompatHTMLError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
