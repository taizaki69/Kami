import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class MangaPandaSourceFactoryTests: XCTestCase {
    private static let package = "eu.kanade.tachiyomi.extension.en.mangapandaonl"
    private static let sourceID: Int64 = 0x6a52d2d1fc303a8e
    private static let fingerprint = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private static let hash = "00ba5d0cfd65132b6feffee60b7c8d5eca23c4ce4bd5687c7908e6c9f15a3166"

    private actor FixtureTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangapanda-factory-fixture"
        private(set) var requests: [CompatHTTPRequest] = []
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            let url = try XCTUnwrap(URL(string: request.url))
            if url.host == "mangapanda.onl", url.path.hasPrefix("/chapter/martial-peak/chapter-"), request.method == "GET" {
                return .init(finalURL: request.url, statusCode: 200,
                    headers: [.init(name: "Set-Cookie", value: "mhub_access=fixture-token; Path=/; Secure")], body: [])
            }
            if request.url == "https://api.mghcdn.com/graphql", request.method == "POST" {
                XCTAssertTrue(request.headers.contains { $0.name.lowercased() == "x-mhub-access" && $0.value == "fixture-token" })
                XCTAssertFalse(request.headers.contains { $0.name.lowercased() == "cookie" })
                return .init(finalURL: request.url, statusCode: 200, body: Array(
                    #"{"data":{"search":{"rows":[{"title":"Factory Panda","slug":"factory-panda","image":"panda.jpg"}]}}}"#.utf8))
            }
            XCTFail("Unexpected factory fixture request: \(request.url)")
            throw CompatHTTPTransportError.invalidResponse
        }
    }

    private func fixture() throws -> (directory: URL, apk: URL, bytes: [UInt8]) {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/measurement/mangapandaonl.apk")
        let bytes = [UInt8](try Data(contentsOf: corpus))
        XCTAssertEqual(APKSignatureVerifier.apkSHA256(bytes), Self.hash)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-PandaFactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apk = directory.appendingPathComponent("extension.apk")
        try Data(bytes).write(to: apk, options: .atomic)
        return (directory, apk, bytes)
    }

    private func admission(bytes: [UInt8], apk: URL, sourceIDs: Set<Int64>? = nil,
                           version: String = "1.6.36", fingerprint: String? = nil) throws -> ExtensionAdmission {
        .init(packageName: Self.package, versionName: version, versionCode: 36, apkPath: apk.path,
              apkSHA256: Self.hash, signingIdentity: try APKSignatureVerifier().verify(apkBytes: bytes),
              trustSource: .user(fingerprint: fingerprint ?? Self.fingerprint), sourceIDs: sourceIDs ?? [Self.sourceID])
    }

    func testExactFactoryRegistersSourceAndRevokesRetainedSourceAndImage() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admission = try admission(bytes: fixture.bytes, apk: fixture.apk)
        let transport = FixtureTransport()
        let sources = try ExtensionSourceFactory().makeSources(admission: admission, transport: transport)
        XCTAssertEqual(sources.count, 1)
        let rawSource = try XCTUnwrap(sources.first)
        XCTAssertEqual(rawSource.id, Self.sourceID)
        XCTAssertEqual(rawSource.name, "MangaPanda.onl")
        XCTAssertEqual(rawSource.language, "en")
        XCTAssertEqual(rawSource.baseURL, "https://mangapanda.onl")
        XCTAssertTrue(rawSource.supportsLatest)
        XCTAssertTrue(rawSource.supportsFilterFetching)
        XCTAssertFalse(rawSource.transportPolicy.allowsInsecureHTTP)
        let beforeExecution = await transport.requests
        XCTAssertTrue(beforeExecution.isEmpty)
        let registry = await MainActor.run { SourceRegistry() }
        let source = try await MainActor.run {
            try registry.addDownloaded(rawSource, admission: admission)
            XCTAssertEqual(registry.origin(of: Self.sourceID), .downloadedExtension(packageName: Self.package))
            return try XCTUnwrap(registry.source(id: Self.sourceID))
        }
        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.map(\.url), ["/manga/factory-panda"])
        XCTAssertEqual(popular.mangas.map(\.title), ["Factory Panda"])
        let value = await source.getImageRequest(page: .init(index: 0, imageURL: "https://imgx.mghcdn.com/factory-panda/1.jpg"))
        let image = try XCTUnwrap(value)
        XCTAssertNotNil(image.sourceExecutionID)
        await MainActor.run {
            registry.removeDownloaded(sourceIDs: [Self.sourceID], packageName: "unrelated.package")
            XCTAssertNotNil(registry.source(id: Self.sourceID))
            registry.removeDownloaded(sourceIDs: [Self.sourceID], packageName: Self.package)
            XCTAssertNil(registry.source(id: Self.sourceID))
        }
        do { _ = try await source.getPopularManga(page: 1); XCTFail("Retained source must be revoked") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await image.executeSourceRequest(); XCTFail("Retained image must be revoked") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testFactoryRejectsWrongIdentitiesPreferencesAndReplacedFileBeforeHTTP() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = FixtureTransport(), factory = ExtensionSourceFactory()
        for ids: Set<Int64> in [[], [123], [123, Self.sourceID]] {
            let bad = try admission(bytes: fixture.bytes, apk: fixture.apk, sourceIDs: ids)
            XCTAssertThrowsError(try factory.makeSources(admission: bad, transport: transport)) {
                XCTAssertEqual($0 as? ExtensionSourceFactoryError, .sourceIdentityMismatch)
            }
        }
        let wrongManifest = try admission(bytes: fixture.bytes, apk: fixture.apk, version: "1.6.37")
        XCTAssertThrowsError(try factory.makeSources(admission: wrongManifest, transport: transport)) {
            XCTAssertEqual($0 as? ExtensionSourceFactoryError, .manifestIdentityMismatch)
        }
        let wrongSigner = try admission(bytes: fixture.bytes, apk: fixture.apk, fingerprint: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try factory.makeSources(admission: wrongSigner, transport: transport)) {
            XCTAssertEqual($0 as? ExtensionSourceFactoryError, .signerIdentityMismatch)
        }
        let valid = try admission(bytes: fixture.bytes, apk: fixture.apk)
        XCTAssertThrowsError(try factory.makeSources(admission: valid, transport: transport,
            preferences: .init(strings: ["overrideBaseUrl": "https://other.example"]))) {
            XCTAssertEqual($0 as? PinnedInterpretedSourceError, .invalidPreferences(profile: "mangapandaonl-1.6.36"))
        }
        var replaced = fixture.bytes
        replaced[replaced.count / 2] ^= 1
        try Data(replaced).write(to: fixture.apk, options: .atomic)
        XCTAssertThrowsError(try factory.makeSources(admission: valid, transport: transport)) {
            XCTAssertEqual($0 as? ExtensionSourceFactoryError, .apkContentMismatch)
        }
        XCTAssertFalse(InterpretedExtensionProfileCatalog.supports(packageName: Self.package, versionName: "1.6.37", versionCode: 37))
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    #if canImport(SQLite3)
    func testPersistedRepositoryAdmissionRestoresExecutableProfileAndHonorsDisable() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databasePath = fixture.directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: databasePath)
        let entry = ExtensionRepositoryIndex.Extension(
            name: "MangaPanda.onl", packageName: Self.package, versionName: "1.6.36", versionCode: 36,
            extensionLib: "1.6", contentWarning: .safe, apkURL: "https://fixtures.example/mangapanda.apk",
            sources: [.init(id: Self.sourceID, name: "MangaPanda.onl", language: "en", homeURL: "https://mangapanda.onl")])
        _ = try await ExtensionAdmissionService(store: store).admit(
            apkBytes: fixture.bytes, extension: entry, apkPath: fixture.apk.path,
            repositoryURL: "https://fixtures.example/index.pb", repositorySigningKey: Self.fingerprint)
        let reopened = try LibraryStore(path: databasePath)
        let service = ExtensionAdmissionService(store: reopened)
        let admission = try await service.restore(packageName: Self.package)
        XCTAssertEqual(admission.apkSHA256, Self.hash)
        XCTAssertEqual(admission.sourceIDs, [Self.sourceID])
        let transport = FixtureTransport()
        let sources = try ExtensionSourceFactory().makeSources(admission: admission, transport: transport)
        let source = try XCTUnwrap(sources.first)
        let popular = try await source.getPopularManga(page: 1)
        XCTAssertEqual(popular.mangas.map(\.title), ["Factory Panda"])
        try await reopened.setExtensionEnabled(false, packageName: Self.package)
        do { _ = try await service.restore(packageName: Self.package); XCTFail("Disabled installation must not restore") }
        catch { XCTAssertEqual(error as? ExtensionAdmissionError, .extensionDisabled(Self.package)) }
    }
    #endif
}
