import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class FoolSlideSourceFactoryTests: XCTestCase {
    private static let package = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let sourceID: Int64 = 6_351_052_922_295_965_587
    private static let fingerprint =
        "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private static let hash =
        "d45b6d44760cb0465cc7be317d6d1b899c778bb9d7c02d03fb6c2c141dfa137e"

    private actor FixtureTransport: CompatHTTPTransport {
        nonisolated let sourceID = "foolslide-factory"
        private var requests: [CompatHTTPRequest] = []

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return CompatHTTPResponse(
                finalURL: request.url,
                statusCode: 200,
                headers: [.init(name: "Content-Type", value: "text/html; charset=utf-8")],
                body: Array(#"<html><body><div class="group"><a title="Factory Manga" href="/read/factory/en/0/1/">Factory Manga</a><img src="/uploads/factory/thumb_cover.jpg"></div></body></html>"#.utf8)
            )
        }

        func capturedRequests() -> [CompatHTTPRequest] { requests }
    }

    private func fixture() throws -> (directory: URL, apk: URL, bytes: [UInt8]) {
        let corpusURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/foolslidecustomizable.apk")
        let bytes = [UInt8](try Data(contentsOf: corpusURL))
        XCTAssertEqual(APKSignatureVerifier.apkSHA256(bytes), Self.hash)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kami-FoolSlideFactory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apk = directory.appendingPathComponent("extension.apk")
        try Data(bytes).write(to: apk, options: .atomic)
        return (directory, apk, bytes)
    }

    private func admission(
        bytes: [UInt8], apk: URL, sourceIDs: Set<Int64>? = nil
    ) throws -> ExtensionAdmission {
        let identity = try APKSignatureVerifier().verify(apkBytes: bytes)
        XCTAssertEqual(identity.signers.map(\.currentFingerprint), [Self.fingerprint])
        return ExtensionAdmission(
            packageName: Self.package, versionName: "1.6.6", versionCode: 6,
            apkPath: apk.path, apkSHA256: Self.hash, signingIdentity: identity,
            trustSource: .user(fingerprint: Self.fingerprint), sourceIDs: sourceIDs ?? [Self.sourceID]
        )
    }

    private func preferences() throws -> InterpretedExtensionPreferences {
        try .init(strings: ["overrideBaseUrl": "https://foolslide.example"])
    }

    func testAuthenticatedConfiguredFactoryExecutesAndRegistersExactSource() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admission = try admission(bytes: fixture.bytes, apk: fixture.apk)
        let transport = FixtureTransport()
        let sources = try ExtensionSourceFactory().makeSources(
            admission: admission, transport: transport, preferences: preferences()
        )
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.id, Self.sourceID)
        XCTAssertEqual(source.name, "FoolSlide Customizable")
        XCTAssertEqual(source.language, "other")
        XCTAssertEqual(source.baseURL, "https://foolslide.example")
        XCTAssertFalse(source.transportPolicy.allowsInsecureHTTP)
        let constructionRequests = await transport.capturedRequests()
        XCTAssertTrue(constructionRequests.isEmpty)

        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.map(\.title), ["Factory Manga"])
        XCTAssertEqual(popular.mangas.map(\.url), ["/read/factory/en/0/1/"])
        XCTAssertFalse(popular.hasNextPage)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET"])
        XCTAssertEqual(requests.map(\.url), ["https://foolslide.example/directory/1/"])

        try await MainActor.run {
            let registry = SourceRegistry()
            try registry.addDownloaded(source, admission: admission)
            XCTAssertEqual(
                registry.origin(of: Self.sourceID),
                .downloadedExtension(packageName: Self.package)
            )
            registry.removeDownloaded(sourceIDs: [Self.sourceID], packageName: "unrelated.package")
            XCTAssertNotNil(registry.source(id: Self.sourceID))
            registry.removeDownloaded(sourceIDs: [Self.sourceID], packageName: Self.package)
            XCTAssertNil(registry.source(id: Self.sourceID))
        }
    }

    func testFactoryRequiresConfigurationAndPreflightsIdentityBeforePreferences() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = FixtureTransport()
        let factory = ExtensionSourceFactory()
        let admission = try admission(bytes: fixture.bytes, apk: fixture.apk)
        let missingConfigurations: [InterpretedExtensionPreferences?] = [
            nil, .init(), try .init(strings: ["overrideBaseUrl": ""]),
            try .init(strings: ["defaultBaseUrl": "https://foolslide.example"]),
        ]
        for preferences in missingConfigurations {
            XCTAssertThrowsError(try factory.makeSources(
                admission: admission, transport: transport, preferences: preferences
            )) {
                XCTAssertEqual($0 as? ExtensionSourceFactoryError, .sourceConfigurationRequired)
            }
        }
        for sourceIDs: Set<Int64> in [[], [123], [Self.sourceID, 123]] {
            let mismatched = try self.admission(bytes: fixture.bytes, apk: fixture.apk, sourceIDs: sourceIDs)
            XCTAssertThrowsError(try factory.makeSources(admission: mismatched, transport: transport)) {
                XCTAssertEqual($0 as? ExtensionSourceFactoryError, .sourceIdentityMismatch)
            }
        }
        var replaced = fixture.bytes
        replaced[replaced.count / 2] ^= 1
        try Data(replaced).write(to: fixture.apk, options: .atomic)
        XCTAssertThrowsError(try factory.makeSources(admission: admission, transport: transport)) {
            XCTAssertEqual($0 as? ExtensionSourceFactoryError, .apkContentMismatch)
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    #if canImport(SQLite3)
    func testPersistedSignerAdmissionRestoresConfiguredSourceAndRejectsDisabledRecord() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databasePath = fixture.directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: databasePath)
        let service = ExtensionAdmissionService(store: store)
        let entry = ExtensionRepositoryIndex.Extension(
            name: "FoolSlide Customizable", packageName: Self.package,
            versionName: "1.6.6", versionCode: 6, extensionLib: "1.6",
            contentWarning: .mixed, apkURL: "https://fixtures.example/foolslide.apk",
            sources: [.init(id: Self.sourceID, name: "FoolSlide Customizable",
                            language: "other", homeURL: "https://127.0.0.1")]
        )
        _ = try await service.admit(
            apkBytes: fixture.bytes, extension: entry, apkPath: fixture.apk.path,
            repositoryURL: "https://fixtures.example/index.pb",
            repositorySigningKey: Self.fingerprint
        )
        let reopenedStore = try LibraryStore(path: databasePath)
        let restoredService = ExtensionAdmissionService(store: reopenedStore)
        let restored = try await restoredService.restore(packageName: Self.package)
        XCTAssertEqual(restored.apkSHA256, Self.hash)
        XCTAssertEqual(restored.sourceIDs, [Self.sourceID])
        let transport = FixtureTransport()
        let sources = try ExtensionSourceFactory().makeSources(
            admission: restored, transport: transport, preferences: preferences()
        )
        XCTAssertEqual(sources.map(\.id), [Self.sourceID])
        XCTAssertEqual(sources.map(\.baseURL), ["https://foolslide.example"])

        try await reopenedStore.setExtensionEnabled(false, packageName: Self.package)
        do {
            _ = try await restoredService.restore(packageName: Self.package)
            XCTFail("disabled source must not regain a capability")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .extensionDisabled(Self.package))
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }
    #endif
}
