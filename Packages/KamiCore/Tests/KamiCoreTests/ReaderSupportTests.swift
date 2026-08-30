import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class ReaderSupportTests: XCTestCase {
    func testReaderSettingsAndPrefetchPlanAreBounded() {
        let settings = ReaderSettings(
            mode: .webtoon,
            background: .gray,
            keepScreenAwake: false,
            prefetchPages: 99,
            webtoonGap: -4
        )
        XCTAssertEqual(settings.mode, .webtoon)
        XCTAssertEqual(settings.background, .gray)
        XCTAssertFalse(settings.keepScreenAwake)
        XCTAssertEqual(settings.prefetchPages, ReaderSettings.maximumPrefetchPages)
        XCTAssertEqual(settings.webtoonGap, 0)

        XCTAssertEqual(
            ReaderPrefetchPlan.indexes(
                pageCount: 10,
                currentIndex: 4,
                ahead: 3,
                behind: 2
            ),
            [5, 6, 7, 3, 2]
        )
        XCTAssertEqual(
            ReaderPrefetchPlan.indexes(pageCount: 3, currentIndex: 2, ahead: 8),
            [1]
        )
        XCTAssertEqual(
            ReaderPrefetchPlan.indexes(pageCount: 3, currentIndex: 3, ahead: 2),
            []
        )
    }

    func testImagePipelineForwardsHeadersDeduplicatesAndCaches() async throws {
        let transport = RecordingImageTransport(responses: [
            CompatHTTPResponse(
                finalURL: "https://cdn.example/page.jpg",
                statusCode: 200,
                body: [1, 2, 3, 4]
            ),
        ])
        let pipeline = ReaderImagePipeline(
            sourceID: "42",
            maximumImageBytes: 16,
            maximumCacheBytes: 16,
            transport: transport
        )
        let imageRequest = ImageRequest(
            url: "https://cdn.example/page.jpg",
            headers: ["Referer": "https://reader.example", "X-App": "kami"]
        )

        async let first = pipeline.data(for: imageRequest)
        async let second = pipeline.data(for: imageRequest)
        let (firstData, secondData) = try await (first, second)
        let cachedData = try await pipeline.data(for: imageRequest)
        XCTAssertEqual(firstData, Data([1, 2, 3, 4]))
        XCTAssertEqual(secondData, Data([1, 2, 3, 4]))
        XCTAssertEqual(cachedData, Data([1, 2, 3, 4]))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, imageRequest.url)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].headers, [
            CompatHTTPHeader(name: "Referer", value: "https://reader.example"),
            CompatHTTPHeader(name: "X-App", value: "kami"),
        ])
        let statistics = await pipeline.cacheStatistics()
        XCTAssertEqual(statistics.entries, 1)
        XCTAssertEqual(statistics.bytes, 4)
    }

    func testImagePipelineRejectsHTTPEmptyAndOversizedResponses() async throws {
        let transport = RecordingImageTransport(responses: [
            CompatHTTPResponse(finalURL: "https://cdn.example/403", statusCode: 403),
            CompatHTTPResponse(finalURL: "https://cdn.example/empty", statusCode: 200),
            CompatHTTPResponse(
                finalURL: "https://cdn.example/large",
                statusCode: 200,
                body: [1, 2, 3, 4, 5]
            ),
        ])
        let pipeline = ReaderImagePipeline(
            sourceID: "42",
            maximumImageBytes: 4,
            maximumCacheBytes: 8,
            transport: transport
        )

        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: ImageRequest(url: "https://cdn.example/403")),
            equals: ReaderImagePipelineError.httpStatus(403)
        )
        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: ImageRequest(url: "https://cdn.example/empty")),
            equals: ReaderImagePipelineError.emptyBody
        )
        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: ImageRequest(url: "https://cdn.example/large")),
            equals: ReaderImagePipelineError.imageTooLarge(limit: 4)
        )
    }

    func testImagePipelineAppliesSourceHTTPPolicyBeforeInjectedTransport() async throws {
        let transport = RecordingImageTransport(responses: [
            CompatHTTPResponse(
                finalURL: "http://cdn.example/page.jpg",
                statusCode: 200,
                body: [1, 2, 3]
            ),
        ])
        let pipeline = ReaderImagePipeline(
            sourceID: "42",
            maximumImageBytes: 16,
            maximumCacheBytes: 16,
            transport: transport,
            transportPolicy: CompatHTTPTransportPolicy(allowsInsecureHTTP: false)
        )
        let request = ImageRequest(
            url: "http://cdn.example/page.jpg",
            headers: ["Referer": "http://reader.example"]
        )

        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: request),
            equals: CompatHTTPTransportError.disallowedScheme
        )
        let rejectedRequests = await transport.recordedRequests()
        XCTAssertTrue(rejectedRequests.isEmpty)

        let explicitlyInsecurePipeline = ReaderImagePipeline(
            sourceID: "42",
            maximumImageBytes: 16,
            maximumCacheBytes: 16,
            transport: transport,
            transportPolicy: CompatHTTPTransportPolicy(allowsInsecureHTTP: true)
        )
        _ = try await explicitlyInsecurePipeline.data(for: request)
        let recorded = await transport.recordedRequests()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].url, request.url)
        XCTAssertEqual(recorded[0].headers, [
            CompatHTTPHeader(name: "Referer", value: "http://reader.example"),
        ])
    }
}

private actor RecordingImageTransport: CompatHTTPTransport {
    nonisolated let sourceID = "reader-test"
    private var responses: [CompatHTTPResponse]
    private var requests: [CompatHTTPRequest] = []

    init(responses: [CompatHTTPResponse]) {
        self.responses = responses
    }

    func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CompatHTTPTransportError.invalidResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [CompatHTTPRequest] {
        requests
    }
}

private func XCTAssertThrowsErrorAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}
