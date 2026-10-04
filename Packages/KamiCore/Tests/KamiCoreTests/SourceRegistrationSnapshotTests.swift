import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class SourceRegistrationSnapshotTests: XCTestCase {
    private struct Source: KamiSource {
        let id: Int64
        let name: String
        let image: ImageRequest
        let language = "en"
        let baseURL = "https://source.invalid"
        func getPopularManga(page: Int) async throws -> MangasPageCompat { .init(mangas: [], hasNextPage: false) }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            try await getPopularManga(page: page)
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { manga }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { [] }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
        func getImageRequest(page: PageCompat) async -> ImageRequest? { image }
    }

    private func admission() throws -> ExtensionAdmission {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Tests/corpus/batcave.apk")
        let bytes = [UInt8](try Data(contentsOf: path))
        let signing = try APKSignatureVerifier().verify(apkBytes: bytes)
        return ExtensionAdmission(packageName: "test.download.snapshot", versionName: "1", versionCode: 1,
            apkPath: path.path, apkSHA256: APKSignatureVerifier.apkSHA256(bytes), signingIdentity: signing,
            trustSource: .user(fingerprint: signing.signers[0].currentFingerprint), sourceIDs: [10])
    }

    @MainActor
    func testSnapshotUsesPublishedFacadeAndCannotSurviveIdenticalReplacement() async throws {
        let registry = SourceRegistry()
        let admission = try admission()
        let executionID = UUID()
        let raw = ImageRequest(url: "https://images.invalid/page.png", sourceExecutionID: executionID) {
            .init(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [8])
        }
        let source = Source(id: 10, name: "Exact", image: raw)
        try registry.replaceDownloaded(sources: [source], admission: admission)
        let first = try XCTUnwrap(registry.registrationSnapshot(id: 10))
        let generated = await first.source.getImageRequest(page: .init(index: 0))
        let request = try first.scopedImageRequest(XCTUnwrap(generated))
        XCTAssertEqual(request.sourceExecutionID, executionID)
        XCTAssertEqual(request.requestScopeID, first.registrationID)
        try first.checkAvailability()

        try registry.replaceDownloaded(sources: [source], admission: admission)
        let second = try XCTUnwrap(registry.registrationSnapshot(id: 10))
        XCTAssertNotEqual(first.registrationID, second.registrationID)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertThrowsError(try first.checkAvailability()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try second.scopedImageRequest(request))
        let late = await first.source.getImageRequest(page: .init(index: 0))
        XCTAssertNil(late)
        registry.removeDownloaded(packageName: admission.packageName)
        XCTAssertThrowsError(try second.checkAvailability()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(registry.registrationSnapshot(id: 10))
    }

    @MainActor
    func testNativeSnapshotBindsPlainProjectionWithoutGrantingExecution() throws {
        let registry = SourceRegistry()
        let snapshot = try XCTUnwrap(registry.registrationSnapshot(id: MangaDexSource().id))
        let raw = ImageRequest(url: "https://images.invalid/page.png")
        let scoped = try snapshot.scopedImageRequest(raw)
        XCTAssertEqual(snapshot.origin, .native)
        XCTAssertNil(scoped.sourceExecutionID)
        XCTAssertEqual(scoped.requestScopeID, snapshot.registrationID)
        XCTAssertNil(registry.registrationSnapshot(id: -987))
    }

    private actor Executor {
        var calls = 0
        func execute() -> CompatHTTPResponse {
            calls += 1
            return .init(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [UInt8(calls)])
        }
    }

    private actor ForbiddenTransport: CompatHTTPTransport {
        nonisolated let sourceID = "snapshot-forbidden"
        var calls = 0
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            calls += 1
            XCTFail("A retained source executor must not become a direct request")
            throw CancellationError()
        }
    }

    func testDisabledCacheReloadsOriginalOpaqueExecutionAndRetainsNoImageBytes() async throws {
        let executor = Executor()
        let transport = ForbiddenTransport()
        let scope = SourceRequestScope(maximumOperations: 1)
        let request = try ImageRequest(url: "https://images.invalid/page.png", sourceExecutionID: UUID()) {
            await executor.execute()
        }.scoped(to: scope)
        let pipeline = ReaderImagePipeline(sourceID: "download", cachePolicy: .disabled, transport: transport)
        let first = try await pipeline.data(for: request)
        let second = try await pipeline.data(for: request)
        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(second, Data([2]))
        let statistics = await pipeline.cacheStatistics()
        let calls = await executor.calls
        let directCalls = await transport.calls
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.bytes, 0)
        XCTAssertEqual(statistics.inFlightWaiters, 0)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(directCalls, 0)
        scope.revoke()
        do {
            _ = try await pipeline.data(for: request)
            XCTFail("Disabled caching still requires the source lifetime")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    }
}
