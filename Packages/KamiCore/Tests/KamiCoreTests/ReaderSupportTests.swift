import Foundation
import XCTest
import MihonCompatKit
#if canImport(ImageIO)
import ImageIO
#endif
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
        // A complete one-pixel RGBA PNG, so Apple-hosted verification also
        // proves that the replacement response reaches a working image decode.
        let validImage = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg=="
        ))
        let transport = RecordingImageTransport(responses: [
            CompatHTTPResponse(
                finalURL: "https://cdn.example/page.jpg",
                statusCode: 200,
                // Transport accepts these bytes; the app-level image decoder
                // would reject them. A retry must not replay this cache entry.
                body: [0, 1, 2, 3]
            ),
            CompatHTTPResponse(
                finalURL: "https://cdn.example/page.jpg",
                statusCode: 200,
                body: Array(validImage)
            ),
            CompatHTTPResponse(
                finalURL: "https://cdn.example/page.jpg",
                statusCode: 200,
                body: [5, 6]
            ),
        ])
        let pipeline = ReaderImagePipeline(
            sourceID: "42",
            maximumImageBytes: 128,
            maximumCacheBytes: 256,
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
        let refreshedData = try await pipeline.data(
            for: imageRequest,
            policy: .reload
        )
        let refreshedCachedData = try await pipeline.data(for: imageRequest)
        let changedHeadersRequest = ImageRequest(
            url: imageRequest.url,
            headers: ["Referer": "https://reader.example", "X-App": "refreshed"]
        )
        let changedHeadersData = try await pipeline.data(for: changedHeadersRequest)
        XCTAssertEqual(firstData, Data([0, 1, 2, 3]))
        XCTAssertEqual(secondData, Data([0, 1, 2, 3]))
        XCTAssertEqual(cachedData, Data([0, 1, 2, 3]))
        XCTAssertEqual(refreshedData, validImage)
        XCTAssertEqual(refreshedCachedData, validImage)
        XCTAssertEqual(changedHeadersData, Data([5, 6]))
        #if canImport(ImageIO)
        // ImageIO may create a source for unrecognized bytes. Actual image
        // decoding, rather than source creation, determines reader usability.
        let invalidSource = CGImageSourceCreateWithData(cachedData as CFData, nil)
        let invalidImage = invalidSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNil(invalidImage)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(refreshedData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        #endif

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url, imageRequest.url)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].headers, [
            CompatHTTPHeader(name: "Referer", value: "https://reader.example"),
            CompatHTTPHeader(name: "X-App", value: "kami"),
        ])
        XCTAssertEqual(requests[1].headers, requests[0].headers)
        XCTAssertEqual(requests[2].headers, [
            CompatHTTPHeader(name: "Referer", value: "https://reader.example"),
            CompatHTTPHeader(name: "X-App", value: "refreshed"),
        ])
        let statistics = await pipeline.cacheStatistics()
        XCTAssertEqual(statistics.entries, 2)
        XCTAssertEqual(statistics.bytes, validImage.count + 2)
    }

    func testImagePipelineReloadReplacesOrdinaryFlightAndDeduplicatesReloads() async throws {
        let ordinaryStarted = expectation(description: "ordinary image request started")
        let reloadStarted = expectation(description: "reload image request started")
        let transport = GatedImageTransport(fallbackResponse: CompatHTTPResponse(
            finalURL: "https://cdn.example/gated.jpg",
            statusCode: 200,
            body: [9, 8, 7]
        ), onRequest: { count in
            if count == 1 { ordinaryStarted.fulfill() }
            if count == 2 { reloadStarted.fulfill() }
        })
        defer { Task { await transport.finish() } }
        let pipeline = ReaderImagePipeline(
            sourceID: "reload-gate",
            maximumImageBytes: 16,
            maximumCacheBytes: 16,
            transport: transport
        )
        let imageRequest = ImageRequest(url: "https://cdn.example/gated.jpg")

        let ordinary = Task<Data, Error> {
            try await pipeline.data(for: imageRequest)
        }
        guard await XCTWaiter.fulfillment(of: [ordinaryStarted], timeout: 5) == .completed else {
            ordinary.cancel()
            XCTFail("ordinary image request did not start")
            return
        }

        let reload = Task<Data, Error> {
            try await pipeline.data(for: imageRequest, policy: .reload)
        }
        guard await XCTWaiter.fulfillment(of: [reloadStarted], timeout: 5) == .completed else {
            ordinary.cancel()
            reload.cancel()
            XCTFail("reload did not replace the ordinary flight")
            return
        }

        // A canceled transport may finish late. Its completion must not remove
        // the replacement flight that is still waiting for its own response.
        await transport.resumeNext(with: CompatHTTPResponse(
            finalURL: imageRequest.url,
            statusCode: 200,
            body: [1, 2, 3]
        ))
        do {
            _ = try await ordinary.value
            XCTFail("ordinary prefetch should be canceled by reload")
        } catch is CancellationError {
            // Expected: the stale ordinary flight must not publish its body.
        }

        // Keep the replacement flight suspended while the second reload call
        // enters the actor. It must join the active reload instead of causing a
        // third exchange.
        let concurrentReload = Task<Data, Error> {
            try await pipeline.data(for: imageRequest, policy: .reload)
        }
        let joined = expectation(description: "concurrent retry joined the reload")
        let observer = Task {
            while !Task.isCancelled {
                if await pipeline.cacheStatistics().inFlightWaiters == 2 {
                    joined.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        let joinResult = await XCTWaiter.fulfillment(of: [joined], timeout: 5)
        observer.cancel()
        guard joinResult == .completed else {
            reload.cancel()
            concurrentReload.cancel()
            XCTFail("concurrent retry did not join the active reload")
            return
        }

        // Canceling the initiating caller must not discard the shared result
        // needed by the other retry or by a later ordinary cache lookup.
        reload.cancel()
        await transport.resumeNext(with: CompatHTTPResponse(
            finalURL: imageRequest.url,
            statusCode: 200,
            body: [9, 8, 7]
        ))

        do {
            _ = try await reload.value
            XCTFail("Canceled initiating waiter must not receive shared bytes")
        } catch is CancellationError {}
        let concurrentlyReloaded = try await concurrentReload.value
        XCTAssertEqual(concurrentlyReloaded, Data([9, 8, 7]))

        let cached = try await pipeline.data(for: imageRequest)
        XCTAssertEqual(cached, Data([9, 8, 7]))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testCancelledJoinedWaiterDoesNotReceiveBytesOrCancelSharedFlight() async throws {
        let started = expectation(description: "shared image request started")
        let response = CompatHTTPResponse(finalURL: "https://cdn.example/shared.jpg", statusCode: 200, body: [3, 4])
        let transport = GatedImageTransport(fallbackResponse: response, onRequest: { count in
            if count == 1 { started.fulfill() }
        })
        defer { Task { await transport.finish() } }
        let pipeline = ReaderImagePipeline(sourceID: "shared-cancellation", transport: transport)
        let request = ImageRequest(url: response.finalURL)
        let initiating = Task { try await pipeline.data(for: request) }
        defer { initiating.cancel() }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed else {
            XCTFail("Shared image request did not start")
            return
        }
        let joined = Task { try await pipeline.data(for: request) }
        defer { joined.cancel() }
        let registered = expectation(description: "second waiter joined")
        let observer = Task {
            while !Task.isCancelled {
                if await pipeline.cacheStatistics().inFlightWaiters == 2 {
                    registered.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        let joinResult = await XCTWaiter.fulfillment(of: [registered], timeout: 5)
        observer.cancel()
        guard joinResult == .completed else {
            XCTFail("Second waiter did not join")
            return
        }
        joined.cancel()
        await transport.resumeNext(with: response)
        do {
            _ = try await joined.value
            XCTFail("Canceled joined waiter must not receive shared bytes")
        } catch is CancellationError {}
        let value = try await initiating.value
        let cached = try await pipeline.data(for: request)
        XCTAssertEqual(value, Data([3, 4]))
        XCTAssertEqual(cached, value)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testImagePipelineUsesSourceScopedExecutionAndSeparatesHiddenCacheIdentity() async throws {
        let directTransport = RecordingImageTransport(responses: [])
        let firstProbe = SourceImageExecutionProbe(body: [7, 7, 7])
        let pipeline = ReaderImagePipeline(
            sourceID: "interpreted-42",
            maximumImageBytes: 16,
            maximumCacheBytes: 32,
            transport: directTransport
        )
        let firstRequest = ImageRequest(
            url: "https://cdn.example/tagged.jpg",
            headers: ["Referer": "https://reader.example"],
            sourceExecutionID: UUID(),
            sourceExecutor: { await firstProbe.execute() }
        )

        async let first = pipeline.data(for: firstRequest)
        async let second = pipeline.data(for: firstRequest)
        let (firstData, secondData) = try await (first, second)
        let cached = try await pipeline.data(for: firstRequest)
        XCTAssertEqual(firstData, Data([7, 7, 7]))
        XCTAssertEqual(secondData, Data([7, 7, 7]))
        XCTAssertEqual(cached, Data([7, 7, 7]))
        let firstExecutionCount = await firstProbe.executionCount()
        let directRequests = await directTransport.recordedRequests()
        XCTAssertEqual(firstExecutionCount, 1)
        XCTAssertTrue(directRequests.isEmpty)

        let secondProbe = SourceImageExecutionProbe(body: [9, 9])
        let distinctHiddenRequest = ImageRequest(
            url: firstRequest.url,
            headers: firstRequest.headers,
            sourceExecutionID: UUID(),
            sourceExecutor: { await secondProbe.execute() }
        )
        let distinctData = try await pipeline.data(for: distinctHiddenRequest)
        XCTAssertEqual(distinctData, Data([9, 9]))
        let secondExecutionCount = await secondProbe.executionCount()
        XCTAssertEqual(secondExecutionCount, 1)
        let statistics = await pipeline.cacheStatistics()
        XCTAssertEqual(statistics.entries, 2)
        XCTAssertEqual(statistics.bytes, 5)

        let blockedProbe = SourceImageExecutionProbe(body: [4])
        let blockedRequest = ImageRequest(
            url: "http://cdn.example/tagged.jpg",
            sourceExecutionID: UUID(),
            sourceExecutor: { await blockedProbe.execute() }
        )
        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: blockedRequest),
            equals: CompatHTTPTransportError.disallowedScheme
        )
        let blockedExecutionCount = await blockedProbe.executionCount()
        XCTAssertEqual(blockedExecutionCount, 0)
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

extension ReaderSupportTests {
    func testPressurePurgesCacheAndStopsRefillingAcrossChapterResets() async throws {
        let request = ImageRequest(url: "https://cdn.example/pressure.jpg", headers: ["Referer": "https://reader.example"])
        let response = CompatHTTPResponse(finalURL: request.url, statusCode: 200, body: [1, 2, 3])
        let transport = RecordingImageTransport(responses: Array(repeating: response, count: 4))
        let pipeline = ReaderImagePipeline(sourceID: "pressure", transport: transport)
        await pipeline.prefetch([request])
        let before = await pipeline.cacheStatistics()
        XCTAssertEqual(before.entries, 1)
        await pipeline.handleMemoryPressure()
        await pipeline.handleMemoryPressure()
        let purged = await pipeline.cacheStatistics()
        XCTAssertEqual(purged.entries, 0); XCTAssertEqual(purged.bytes, 0)
        await pipeline.prefetch([request])
        _ = try await pipeline.data(for: request)
        _ = try await pipeline.data(for: request, policy: .reload)
        await pipeline.clear()
        await pipeline.prefetch([request])
        _ = try await pipeline.data(for: request)
        let after = await pipeline.cacheStatistics()
        XCTAssertEqual(after.entries, 0); XCTAssertEqual(after.bytes, 0)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.headers == [CompatHTTPHeader(name: "Referer", value: "https://reader.example")] })
        await XCTAssertThrowsErrorAsync(
            try await pipeline.data(for: ImageRequest(url: "http://cdn.example/pressure.jpg")),
            equals: CompatHTTPTransportError.disallowedScheme)
        let validatedRequests = await transport.recordedRequests()
        XCTAssertEqual(validatedRequests.count, 4)
    }

    func testPressurePreservesPrefetchThatAcquiredVisibleWaiterAndDropsOtherWork() async throws {
        let started = expectation(description: "two prefetches entered transport")
        let response = CompatHTTPResponse(finalURL: "https://cdn.example/visible.jpg", statusCode: 200, body: [7, 7])
        let transport = GatedImageTransport(fallbackResponse: response, onRequest: { if $0 == 2 { started.fulfill() } })
        defer { Task { await transport.finish() } }
        let pipeline = ReaderImagePipeline(sourceID: "pressure-shared", transport: transport)
        let visibleRequest = ImageRequest(url: response.finalURL)
        let speculativeRequest = ImageRequest(url: "https://cdn.example/speculative.jpg")
        let prefetch = Task { await pipeline.prefetch([visibleRequest, speculativeRequest]) }
        defer { prefetch.cancel() }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed else {
            return XCTFail("Prefetch did not start")
        }
        let visible = Task { try await pipeline.data(for: visibleRequest) }
        defer { visible.cancel() }
        guard await waitForWaiters(pipeline, total: 3, visible: 1) else { return }
        await pipeline.handleMemoryPressure()
        let preserved = await pipeline.cacheStatistics()
        XCTAssertEqual(preserved.inFlightWaiters, 2)
        XCTAssertEqual(preserved.visibleWaiters, 1)
        // The transport deliberately completes canceled work late. Its result
        // cannot populate the cache, remove the visible flight or leak bytes.
        let requests = await transport.recordedRequests()
        for request in requests {
            await transport.resumeNext(with: CompatHTTPResponse(finalURL: request.url, statusCode: 200,
                                                                body: request.url == visibleRequest.url ? [7, 7] : [9, 9]))
        }
        let data = try await visible.value
        await prefetch.value
        XCTAssertEqual(data, Data([7, 7]))
        let after = await pipeline.cacheStatistics()
        XCTAssertEqual(after.bytes, 0); XCTAssertEqual(after.inFlightWaiters, 0)
        let finalRequests = await transport.recordedRequests()
        XCTAssertEqual(finalRequests.count, 2)
    }

    func testCanceledVisibleOwnershipDoesNotProtectSpeculativeWorkFromPressure() async throws {
        // Exercise cancellation both before the warning and after a shared
        // flight was temporarily protected by its visible waiter.
        for pressureFirst in [false, true] {
            let started = expectation(description: "prefetch started \(pressureFirst)")
            let response = CompatHTTPResponse(finalURL: "https://cdn.example/cancel.jpg", statusCode: 200, body: [4])
            let transport = GatedImageTransport(fallbackResponse: response, onRequest: { if $0 == 1 { started.fulfill() } })
            defer { Task { await transport.finish() } }
            let pipeline = ReaderImagePipeline(sourceID: "pressure-canceled", transport: transport)
            let request = ImageRequest(url: response.finalURL)
            let prefetch = Task { await pipeline.prefetch([request]) }
            defer { prefetch.cancel() }
            guard await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed else {
                return XCTFail("Prefetch did not start")
            }
            let visible = Task { try await pipeline.data(for: request) }
            defer { visible.cancel() }
            guard await waitForWaiters(pipeline, total: 2, visible: 1) else { return }
            if pressureFirst { await pipeline.handleMemoryPressure() }
            visible.cancel()
            guard await waitForWaiters(pipeline, total: pressureFirst ? 0 : 1, visible: 0) else { return }
            await pipeline.handleMemoryPressure()
            let after = await pipeline.cacheStatistics()
            XCTAssertEqual(after.inFlightWaiters, 0)
            await transport.resumeNext(with: response)
            do {
                _ = try await visible.value
                XCTFail("Canceled visible caller received bytes")
            } catch is CancellationError {}
            await prefetch.value
            let finished = await pipeline.cacheStatistics()
            XCTAssertEqual(finished.bytes, 0)
        }
    }

    func testLatePressureCanceledPrefetchCannotSupersedeNewVisibleFlight() async throws {
        let firstStarted = expectation(description: "prefetch started")
        let secondStarted = expectation(description: "visible replacement started")
        let response = CompatHTTPResponse(finalURL: "https://cdn.example/replacement.jpg", statusCode: 200, body: [8])
        let transport = GatedImageTransport(fallbackResponse: response, onRequest: {
            if $0 == 1 { firstStarted.fulfill() }
            if $0 == 2 { secondStarted.fulfill() }
        })
        defer { Task { await transport.finish() } }
        let pipeline = ReaderImagePipeline(sourceID: "pressure-replacement", transport: transport)
        let request = ImageRequest(url: response.finalURL)
        let prefetch = Task { await pipeline.prefetch([request]) }
        defer { prefetch.cancel() }
        guard await XCTWaiter.fulfillment(of: [firstStarted], timeout: 5) == .completed else {
            return XCTFail("Prefetch did not start")
        }
        await pipeline.handleMemoryPressure()
        let visible = Task { try await pipeline.data(for: request) }
        defer { visible.cancel() }
        guard await XCTWaiter.fulfillment(of: [secondStarted], timeout: 5) == .completed else {
            return XCTFail("Visible replacement did not start")
        }
        await transport.resumeNext(with: CompatHTTPResponse(finalURL: request.url, statusCode: 200, body: [1]))
        await prefetch.value
        let pending = await pipeline.cacheStatistics()
        XCTAssertEqual(pending.inFlightWaiters, 1); XCTAssertEqual(pending.visibleWaiters, 1)
        await transport.resumeNext(with: response)
        let value = try await visible.value
        XCTAssertEqual(value, Data([8]))
        let after = await pipeline.cacheStatistics()
        XCTAssertEqual(after.bytes, 0); XCTAssertEqual(after.inFlightWaiters, 0)
    }

    private func waitForWaiters(_ pipeline: ReaderImagePipeline, total: Int, visible: Int) async -> Bool {
        let registered = expectation(description: "waiters total=\(total) visible=\(visible)")
        let observer = Task {
            while !Task.isCancelled {
                let state = await pipeline.cacheStatistics()
                if state.inFlightWaiters == total && state.visibleWaiters == visible {
                    registered.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        let result = await XCTWaiter.fulfillment(of: [registered], timeout: 5)
        observer.cancel()
        if result != .completed { XCTFail("Waiter ownership did not settle") }
        return result == .completed
    }
}

private actor SourceImageExecutionProbe {
    private let response: CompatHTTPResponse
    private var count = 0

    init(body: [UInt8]) {
        response = CompatHTTPResponse(
            finalURL: "https://cdn.example/tagged.jpg",
            statusCode: 200,
            body: body
        )
    }

    func execute() -> CompatHTTPResponse {
        count += 1
        return response
    }

    func executionCount() -> Int { count }
}

private actor GatedImageTransport: CompatHTTPTransport {
    nonisolated let sourceID = "reader-gated-test"
    private let fallbackResponse: CompatHTTPResponse
    private let onRequest: @Sendable (Int) -> Void
    private var requests: [CompatHTTPRequest] = []
    private var responseWaiters: [CheckedContinuation<CompatHTTPResponse, any Error>] = []
    private var isFinished = false

    init(
        fallbackResponse: CompatHTTPResponse,
        onRequest: @escaping @Sendable (Int) -> Void
    ) {
        self.fallbackResponse = fallbackResponse
        self.onRequest = onRequest
    }

    func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
        guard !isFinished else { throw CancellationError() }
        requests.append(request)
        onRequest(requests.count)
        // A third exchange means the second reload missed the active reload
        // flight. Return a response immediately so the assertion can report
        // the duplicate without leaving a suspended continuation behind.
        if requests.count > 2 {
            return fallbackResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    func resumeNext(with response: CompatHTTPResponse) {
        guard !responseWaiters.isEmpty else { return }
        responseWaiters.removeFirst().resume(returning: response)
    }

    func finish() {
        isFinished = true
        let pending = responseWaiters
        responseWaiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
    }

    func recordedRequests() -> [CompatHTTPRequest] {
        requests
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
