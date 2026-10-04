import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class SourceLifetimeTests: XCTestCase {
    private struct Source: KamiSource {
        let id: Int64
        let name: String
        var image: ImageRequest? = nil
        let language = "en"
        let baseURL = "https://source.invalid"
        func getPopularManga(page: Int) async throws -> MangasPageCompat {
            .init(mangas: [.init(url: "/series", title: name)], hasNextPage: false)
        }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            try await getPopularManga(page: page)
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { manga }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { [] }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
        func getImageRequest(page: PageCompat) async -> ImageRequest? {
            image ?? ImageRequest(url: "https://images.invalid/page.png")
        }
    }

    private func admission(_ ids: Set<Int64>, package: String = "test.lifetime") throws -> ExtensionAdmission {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Tests/corpus/batcave.apk")
        let bytes = [UInt8](try Data(contentsOf: path))
        let signing = try APKSignatureVerifier().verify(apkBytes: bytes)
        return ExtensionAdmission(packageName: package, versionName: "test", versionCode: 1,
            apkPath: path.path, apkSHA256: APKSignatureVerifier.apkSHA256(bytes),
            signingIdentity: signing, trustSource: .user(fingerprint: signing.signers[0].currentFingerprint),
            sourceIDs: ids)
    }

    @MainActor
    func testReplacementValidatesEntireSetBeforeChangingOwnersOrRevisions() async throws {
        let registry = SourceRegistry()
        let original = try admission([10, 11])
        try registry.replaceDownloaded(sources: [Source(id: 10, name: "A"), Source(id: 11, name: "B")],
                                        admission: original)
        try registry.replaceDownloaded(sources: [Source(id: 20, name: "Other")],
                                        admission: admission([20], package: "test.other"))
        let retained = try XCTUnwrap(registry.source(id: 10))
        let revision = registry.revision(for: 10)
        let otherRevision = registry.revision(for: 20)
        XCTAssertThrowsError(try registry.replaceDownloaded(
            sources: [Source(id: 10, name: "Partial"), Source(id: 20, name: "Collision")],
            admission: admission([10, 20])))
        XCTAssertEqual(registry.source(id: 10)?.name, "A")
        XCTAssertEqual(registry.source(id: 11)?.name, "B")
        XCTAssertEqual(registry.source(id: 20)?.name, "Other")
        XCTAssertEqual(registry.revision(for: 10), revision)
        let stillActive = try await retained.getPopularManga(page: 1)
        XCTAssertEqual(stillActive.mangas.first?.title, "A")
        XCTAssertThrowsError(try registry.replaceDownloaded(
            sources: [Source(id: 10, name: "Duplicate"), Source(id: 10, name: "Duplicate")], admission: original)) {
                XCTAssertEqual($0 as? SourceRegistryError, .sourceSetMismatch)
            }
        XCTAssertThrowsError(try registry.replaceDownloaded(sources: [], admission: original))

        try registry.replaceDownloaded(sources: [Source(id: 12, name: "Replacement")], admission: admission([12]))
        XCTAssertNil(registry.source(id: 10))
        XCTAssertNil(registry.source(id: 11))
        XCTAssertEqual(registry.source(id: 12)?.name, "Replacement")
        XCTAssertEqual(registry.revision(for: 10), revision + 1)
        XCTAssertEqual(registry.revision(for: 20), otherRevision)
        do {
            _ = try await retained.getPopularManga(page: 1)
            XCTFail("A retained removed source must be revoked")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        registry.removeDownloaded(packageName: original.packageName)
        let removedRevision = registry.revision(for: 12)
        registry.removeDownloaded(packageName: original.packageName)
        XCTAssertEqual(registry.revision(for: 12), removedRevision)
        XCTAssertNil(registry.source(id: 12))
        XCTAssertEqual(registry.source(id: 20)?.name, "Other")
    }

    @MainActor
    func testRetainedSourceImageCapabilityIsRevokedOnReplacement() async throws {
        let registry = SourceRegistry()
        let identity = try admission([10])
        let executionID = UUID()
        let image = ImageRequest(url: "https://images.invalid/page.png", sourceExecutionID: executionID) {
            CompatHTTPResponse(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [4])
        }
        try registry.replaceDownloaded(sources: [Source(id: 10, name: "Old", image: image)], admission: identity)
        let oldSource = try XCTUnwrap(registry.source(id: 10))
        let candidate = await oldSource.getImageRequest(page: .init(index: 0))
        let request = try XCTUnwrap(candidate)
        XCTAssertEqual(request.sourceExecutionID, executionID)
        XCTAssertNotNil(request.requestScopeID)
        let before = try await request.executeSourceRequest()
        XCTAssertEqual(before?.body, [4])
        try registry.replaceDownloaded(sources: [Source(id: 10, name: "New")], admission: identity)
        do {
            _ = try await request.executeSourceRequest()
            XCTFail("Old image executor must be revoked")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let after = await oldSource.getImageRequest(page: .init(index: 0))
        XCTAssertNil(after)
    }

    private actor ImageTransport: CompatHTTPTransport {
        nonisolated let sourceID = "lifetime-image-test"
        private(set) var calls = 0
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            calls += 1
            return .init(finalURL: request.url, statusCode: 200, body: [UInt8(calls)])
        }
    }

    func testSourceImageExecutionUsesOneLifetimeOperationSlot() async throws {
        let transport = ImageTransport()
        let pipeline = ReaderImagePipeline(sourceID: "test", transport: transport)
        let scope = SourceRequestScope(maximumOperations: 1)
        let request = try ImageRequest(url: "https://images.invalid/page.png", sourceExecutionID: UUID()) {
            .init(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [7])
        }.scoped(to: scope)
        let data = try await pipeline.data(for: request)
        XCTAssertEqual(data, Data([7]))
        let directCalls = await transport.calls
        XCTAssertEqual(directCalls, 0)
        let recovered = try await scope.perform { true }
        XCTAssertTrue(recovered)
    }

    func testImageCacheRejectsRevokedRequestsAndSeparatesNewRegistration() async throws {
        let transport = ImageTransport()
        let pipeline = ReaderImagePipeline(sourceID: "test", transport: transport)
        let firstScope = SourceRequestScope()
        let raw = ImageRequest(url: "https://images.invalid/page.png")
        let first = try raw.scoped(to: firstScope)
        let initial = try await pipeline.data(for: first)
        let cached = try await pipeline.data(for: first)
        XCTAssertEqual(initial, Data([1]))
        XCTAssertEqual(cached, initial)
        firstScope.revoke()
        do {
            _ = try await pipeline.data(for: first)
            XCTFail("Revoked request must not replay cached bytes")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let second = try raw.scoped(to: SourceRequestScope())
        let refreshed = try await pipeline.data(for: second)
        XCTAssertEqual(refreshed, Data([2]))
        let calls = await transport.calls
        XCTAssertEqual(calls, 2)
    }

    func testImageHeadersCannotImpersonateHiddenCacheIdentityFields() async throws {
        let transport = ImageTransport()
        let pipeline = ReaderImagePipeline(sourceID: "identity-test", transport: transport)
        let scope = SourceRequestScope()
        let executionID = UUID()
        let url = "https://images.invalid/page.png"
        let executionHeader = try ImageRequest(url: url,
            headers: ["source-execution": executionID.uuidString]).scoped(to: scope)
        let executed = try ImageRequest(url: url, sourceExecutionID: executionID) {
            .init(finalURL: url, statusCode: 200, body: [99])
        }.scoped(to: scope)
        let headerBytes = try await pipeline.data(for: executionHeader)
        let executedBytes = try await pipeline.data(for: executed)
        XCTAssertEqual(headerBytes, Data([1]))
        XCTAssertEqual(executedBytes, Data([99]))

        let lifetimeHeader = ImageRequest(url: url, headers: ["source-lifetime": scope.id.uuidString])
        let scoped = try ImageRequest(url: url).scoped(to: scope)
        let lifetimeHeaderBytes = try await pipeline.data(for: lifetimeHeader)
        let scopedBytes = try await pipeline.data(for: scoped)
        XCTAssertEqual(lifetimeHeaderBytes, Data([2]))
        XCTAssertEqual(scopedBytes, Data([3]))
        let requests = await transport.calls
        let statistics = await pipeline.cacheStatistics()
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(statistics.entries, 4)
    }

    private actor DelayedTransport: CompatHTTPTransport {
        nonisolated let sourceID = "delayed-lifetime-test"
        private var response: CheckedContinuation<CompatHTTPResponse, Never>?
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var cancelled = false
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            let result = await withCheckedContinuation { continuation in
                response = continuation
                entered = true
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
            cancelled = Task.isCancelled
            return result
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            response?.resume(returning: .init(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [9]))
            response = nil
        }
    }

    func testRevocationCancelsPlainImageTransportAndDoesNotCacheLateResponse() async throws {
        let transport = DelayedTransport()
        let pipeline = ReaderImagePipeline(sourceID: "test", transport: transport)
        let scope = SourceRequestScope()
        let request = try ImageRequest(url: "https://images.invalid/page.png").scoped(to: scope)
        let load = Task { try await pipeline.data(for: request) }
        await transport.waitUntilEntered()
        scope.revoke()
        await transport.release()
        do {
            _ = try await load.value
            XCTFail("A late image from the old registration must be discarded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = await transport.cancelled
        let statistics = await pipeline.cacheStatistics()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.inFlightWaiters, 0)
    }
}
