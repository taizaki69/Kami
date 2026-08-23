import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class SourceRegistryTests: XCTestCase {
    private struct DummySource: KamiSource {
        let id: Int64
        let name: String
        let language = "en"
        let baseURL = "https://example.invalid"

        func getPopularManga(page: Int) async throws -> MangasPageCompat {
            MangasPageCompat(mangas: [], hasNextPage: false)
        }
        func getSearchManga(
            page: Int,
            query: String,
            filters: [SourceFilter]
        ) async throws -> MangasPageCompat {
            MangasPageCompat(mangas: [], hasNextPage: false)
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { manga }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { [] }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
    }

    private actor NoNetworkTransport: CompatHTTPTransport {
        nonisolated let sourceID = "batcave-registry-test"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("registry test must not perform network I/O: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/KamiCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KamiCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami (repo root)
            .appendingPathComponent("Tests/corpus/batcave.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK batcave.apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    func testRegistryAcceptsPinnedInterpretedSourceAndDeduplicatesItsID() async throws {
        let source = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK(),
            transport: NoNetworkTransport()
        )
        try await MainActor.run {
            let registry = SourceRegistry()
            let initialCount = registry.sources.count

            registry.addPinned(source)
            registry.addPinned(source)

            XCTAssertEqual(registry.sources.count, initialCount + 1)
            let registered = try XCTUnwrap(registry.source(id: source.id))
            XCTAssertEqual(registered.name, "BatCave")
            XCTAssertEqual(registered.language, "en")
            XCTAssertEqual(registered.baseURL, "https://batcave.biz")
            XCTAssertEqual(registry.origin(of: source.id), .pinnedCompatibilityProfile)
        }
    }

    func testDownloadedSourcesReplaceOnUpdateDisableCleanlyAndCannotShadowNative() async throws {
        let bytes = try corpusAPK()
        let identity = try APKSignatureVerifier().verify(apkBytes: bytes)
        let downloadedID: Int64 = 777
        let admission = ExtensionAdmission(
            packageName: "example.downloaded",
            versionName: "1.0",
            versionCode: 1,
            apkPath: "/private/extensions/example.apk",
            apkSHA256: APKSignatureVerifier.apkSHA256(bytes),
            signingIdentity: identity,
            trustSource: .user(fingerprint: identity.signers[0].currentFingerprint),
            sourceIDs: [downloadedID]
        )

        try await MainActor.run {
            let registry = SourceRegistry()
            try registry.addDownloaded(
                DummySource(id: downloadedID, name: "First runtime"),
                admission: admission
            )
            try registry.addDownloaded(
                DummySource(id: downloadedID, name: "Updated runtime"),
                admission: admission
            )
            XCTAssertEqual(registry.source(id: downloadedID)?.name, "Updated runtime")
            XCTAssertEqual(
                registry.origin(of: downloadedID),
                .downloadedExtension(packageName: admission.packageName)
            )

            registry.removeDownloaded(sourceIDs: admission.sourceIDs)
            XCTAssertNil(registry.source(id: downloadedID))
            XCTAssertNil(registry.origin(of: downloadedID))

            let native = try XCTUnwrap(registry.sources.first)
            let collision = ExtensionAdmission(
                packageName: admission.packageName,
                versionName: admission.versionName,
                versionCode: admission.versionCode,
                apkPath: admission.apkPath,
                apkSHA256: admission.apkSHA256,
                signingIdentity: admission.signingIdentity,
                trustSource: admission.trustSource,
                sourceIDs: [native.id]
            )
            XCTAssertThrowsError(
                try registry.addDownloaded(
                    DummySource(id: native.id, name: "Collision"),
                    admission: collision
                )
            ) {
                XCTAssertEqual(
                    $0 as? ExtensionAdmissionError,
                    .sourceIDCollision(native.id)
                )
            }
            XCTAssertEqual(registry.origin(of: native.id), .native)
        }
    }
}
