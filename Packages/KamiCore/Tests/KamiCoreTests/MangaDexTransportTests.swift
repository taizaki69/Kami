import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class MangaDexTransportTests: XCTestCase {
    private static let details = #"{"result":"ok","data":{"id":"series-id","attributes":{"title":{"en":"Offline series"},"status":"ongoing"}}}"#
    private static let aggregate = #"{"volumes":{"1":{"chapters":{"1":{"chapter":"1","id":"chapter-1"},"2":{"chapter":"2","id":"chapter-2"}}}}}"#

    private actor Transport: CompatHTTPTransport {
        nonisolated let sourceID = "mangadex-fixture"
        private var responses: [CompatHTTPResponse]
        private(set) var requests: [CompatHTTPRequest] = []

        init(_ responses: [CompatHTTPResponse]) { self.responses = responses }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw MangaDexSourceError.invalidResponse }
            return responses.removeFirst()
        }
    }

    private func response(_ body: String, status: Int = 200) -> CompatHTTPResponse {
        .init(finalURL: "https://api.mangadex.org/fixture", statusCode: status, body: Array(body.utf8))
    }

    func testCombinedUpdateUsesBoundedTransportAndKeepsChapterOrder() async throws {
        let transport = Transport([response(Self.details), response(Self.aggregate)])
        let source = MangaDexSource(transport: transport)
        let update = try await source.getMangaUpdate(manga: .init(url: "series-id", title: "Old"))
        XCTAssertEqual(update.manga.title, "Offline series")
        XCTAssertEqual(update.chapters.map(\.url), ["chapter-2", "chapter-1"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(URL(string: requests[0].url)?.path, "/manga/series-id")
        XCTAssertEqual(URL(string: requests[1].url)?.path, "/manga/series-id/aggregate")
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(requests.allSatisfy { request in
            request.headers.contains { $0.name == "User-Agent" && $0.value.contains("Kami/") }
        })
    }

    func testHTTPFailureStopsCombinedUpdateBeforeChapterRequest() async throws {
        for status in [429, 503] {
            let transport = Transport([response(Self.details, status: status), response(Self.aggregate)])
            let source = MangaDexSource(transport: transport)
            do {
                _ = try await source.getMangaUpdate(manga: .init(url: "series-id"))
                XCTFail("An HTTP failure must not be stored as a successful library refresh")
            } catch {
                XCTAssertEqual(error as? MangaDexSourceError, .httpStatus(status))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testIncompleteAggregateCannotEraseCurrentChapters() async throws {
        let bodies = [#"{}"#, #"{"result":"error","volumes":{}}"#, #"{"volumes":{"1":{}}}"#,
                      #"{"volumes":{"1":{"chapters":{"1":{"chapter":"1"}}}}}"#,
                      #"{"volumes":{"1":{"chapters":{"1":{"id":""}}}}}"#]
        for body in bodies {
            let source = MangaDexSource(transport: Transport([response(body)]))
            do {
                _ = try await source.getChapterList(manga: .init(url: "series-id"))
                XCTFail("An incomplete aggregate must fail instead of returning an empty catalog")
            } catch {
                XCTAssertEqual(error as? MangaDexSourceError, .invalidResponse)
            }
        }
        let empty = MangaDexSource(transport: Transport([response(#"{"volumes":{}}"#)]))
        let chapters = try await empty.getChapterList(manga: .init(url: "series-id"))
        XCTAssertTrue(chapters.isEmpty, "An explicit empty catalog remains a successful baseline")
    }

    func testCatalogErrorsAreNotPresentedAsEmptySuccessfulSearches() async throws {
        for body in [#"{"result":"error","data":[]}"#, #"{"result":"ok"}"#] {
            let source = MangaDexSource(transport: Transport([response(body)]))
            do {
                _ = try await source.getPopularManga(page: 1)
                XCTFail("An API failure must not become an empty successful catalog")
            } catch { XCTAssertEqual(error as? MangaDexSourceError, .invalidResponse) }
        }
        let empty = MangaDexSource(transport: Transport([response(#"{"result":"ok","data":[]}"#)]))
        let page = try await empty.getPopularManga(page: 1)
        XCTAssertTrue(page.mangas.isEmpty)
        XCTAssertFalse(page.hasNextPage)
    }

    func testAPIFailureFlagRejectsOtherwiseDecodableMetadataAndPages() async throws {
        let failedDetails = Self.details.replacingOccurrences(of: #""result":"ok""#, with: #""result":"error""#)
        let transport = Transport([response(failedDetails), response(Self.aggregate)])
        let source = MangaDexSource(transport: transport)
        do {
            _ = try await source.getMangaUpdate(manga: .init(url: "series-id"))
            XCTFail("The API's failure flag must stop the combined refresh")
        } catch { XCTAssertEqual(error as? MangaDexSourceError, .invalidResponse) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)

        let pages = MangaDexSource(transport: Transport([response(
            #"{"result":"error","baseUrl":"https://images.invalid","chapter":{"hash":"hash","data":[],"dataSaver":[]}}"#
        )]))
        do {
            _ = try await pages.getPageList(chapter: .init(url: "chapter-id"))
            XCTFail("A failed page request must remain retryable instead of returning an empty reader")
        } catch { XCTAssertEqual(error as? MangaDexSourceError, .invalidResponse) }
    }

    func testPaginationRejectsInvalidInputAndDoesNotOverflowOnServerCounts() async throws {
        let transport = Transport([response(#"{"result":"ok","data":[{"id":"series-id","attributes":{}}],"offset":9223372036854775807,"total":9223372036854775807}"#)])
        let source = MangaDexSource(transport: transport)
        for page in [0, -1, Int.max] {
            do {
                _ = try await source.getPopularManga(page: page)
                XCTFail("Invalid page must be rejected before a request")
            } catch { XCTAssertEqual(error as? MangaDexSourceError, .invalidRequest) }
        }
        let page = try await source.getPopularManga(page: 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(page.mangas.count, 1)
        XCTAssertFalse(page.hasNextPage)
    }

    func testOversizedInjectedResponseIsRejectedBeforeJSONDecoding() async throws {
        let transport = Transport([.init(finalURL: "https://api.mangadex.org/fixture", statusCode: 200,
            body: Array(repeating: 32, count: MangaDexSource.maximumAPIResponseBytes + 1))])
        let source = MangaDexSource(transport: transport)
        do {
            _ = try await source.getMangaDetails(manga: .init(url: "series-id"))
            XCTFail("The API response budget applies before JSON decoding")
        } catch {
            XCTAssertEqual(error as? CompatHTTPTransportError,
                           .responseBodyTooLarge(limit: MangaDexSource.maximumAPIResponseBytes))
        }
    }

    private actor GatedTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangadex-cancellation-fixture"
        let entered: XCTestExpectation
        let result: CompatHTTPResponse
        private var continuation: CheckedContinuation<CompatHTTPResponse, Never>?
        private var released = false
        private(set) var calls = 0
        private(set) var wasCancelled = false

        init(entered: XCTestExpectation, result: CompatHTTPResponse) {
            self.entered = entered
            self.result = result
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            calls += 1
            entered.fulfill()
            let response: CompatHTTPResponse
            if released { response = result }
            else { response = await withCheckedContinuation { continuation = $0 } }
            wasCancelled = Task.isCancelled
            return response
        }

        func release() {
            released = true
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    func testCancelledUpdateRejectsLateNoncooperativeResponse() async throws {
        let entered = expectation(description: "MangaDex metadata request entered")
        let transport = GatedTransport(entered: entered, result: response(Self.details))
        let source = MangaDexSource(transport: transport)
        let update = Task { try await source.getMangaUpdate(manga: .init(url: "series-id")) }
        await fulfillment(of: [entered], timeout: 2)
        update.cancel()
        await transport.release()
        do {
            _ = try await update.value
            XCTFail("Late metadata must be discarded and no chapter request may follow Cancel")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let calls = await transport.calls
        let wasCancelled = await transport.wasCancelled
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(wasCancelled)
    }
}
