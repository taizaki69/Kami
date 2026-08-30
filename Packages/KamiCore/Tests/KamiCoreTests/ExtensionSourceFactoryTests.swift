import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class ExtensionSourceFactoryTests: XCTestCase {
    private static let batCaveSourceID: Int64 = 7_422_099_479_605_463_706
    private static let mangaMelonSourceID: Int64 = 7_505_916_148_185_744_347
    private static let baoziManhuaSourceID: Int64 = 5_724_751_873_601_868_259
    private static let keiyoushiFingerprint =
        "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

    private actor NoNetworkTransport: CompatHTTPTransport {
        nonisolated let sourceID = "downloaded-factory-test"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("source construction must not perform network I/O: \(request.method)")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }
    }

    private func corpus(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func temporaryAPK(_ bytes: [UInt8]) throws -> (directory: URL, apk: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kami-ExtensionSourceFactoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apk = directory.appendingPathComponent("extension.apk")
        try Data(bytes).write(to: apk, options: .atomic)
        return (directory, apk)
    }

    private func admission(
        apkBytes: [UInt8],
        apkURL: URL,
        sourceIDs: Set<Int64>? = nil
    ) throws -> ExtensionAdmission {
        ExtensionAdmission(
            packageName: "eu.kanade.tachiyomi.extension.en.batcave",
            versionName: "1.6.9",
            versionCode: 9,
            apkPath: apkURL.path,
            apkSHA256: APKSignatureVerifier.apkSHA256(apkBytes),
            signingIdentity: try APKSignatureVerifier().verify(apkBytes: apkBytes),
            trustSource: .user(fingerprint: Self.keiyoushiFingerprint),
            sourceIDs: sourceIDs ?? [Self.batCaveSourceID]
        )
    }

    func testFactoryReauthenticatesExactBytesAndRegistersDeclaredRealSource() async throws {
        let bytes = try corpus("batcave")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let admission = try admission(apkBytes: bytes, apkURL: temporary.apk)

        let sources = try ExtensionSourceFactory().makeSources(
            admission: admission,
            transport: NoNetworkTransport()
        )
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.id, Self.batCaveSourceID)
        XCTAssertEqual(source.name, "BatCave")
        XCTAssertEqual(source.language, "en")
        XCTAssertEqual(source.baseURL, "https://batcave.biz")
        XCTAssertFalse(source.transportPolicy.allowsInsecureHTTP)

        try await MainActor.run {
            let registry = SourceRegistry()
            try registry.addDownloaded(source, admission: admission)
            XCTAssertEqual(
                registry.origin(of: source.id),
                .downloadedExtension(packageName: admission.packageName)
            )
        }
    }

    func testFactoryAdmitsCurrentMangaMelonProfileAndItsStaticFilters() throws {
        let bytes = try corpus("mangamelon")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let admission = ExtensionAdmission(
            packageName: "eu.kanade.tachiyomi.extension.en.mangamelon",
            versionName: "1.6.1",
            versionCode: 1,
            apkPath: temporary.apk.path,
            apkSHA256: APKSignatureVerifier.apkSHA256(bytes),
            signingIdentity: try APKSignatureVerifier().verify(apkBytes: bytes),
            trustSource: .user(fingerprint: Self.keiyoushiFingerprint),
            sourceIDs: [Self.mangaMelonSourceID]
        )

        let sources = try ExtensionSourceFactory().makeSources(
            admission: admission,
            transport: NoNetworkTransport()
        )
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.id, Self.mangaMelonSourceID)
        XCTAssertEqual(source.name, "MangaMelon")
        XCTAssertEqual(source.language, "en")
        XCTAssertEqual(source.getFilterList().count, 2)
    }

    func testFactoryAdmitsExactBaoziProfileThroughRepositoryAdmission() throws {
        let bytes = try corpus("baozimanhua")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let admission = ExtensionAdmission(
            packageName: "eu.kanade.tachiyomi.extension.zh.baozimanhua",
            versionName: "1.6.29",
            versionCode: 29,
            apkPath: temporary.apk.path,
            apkSHA256: APKSignatureVerifier.apkSHA256(bytes),
            signingIdentity: try APKSignatureVerifier().verify(apkBytes: bytes),
            trustSource: .user(fingerprint: Self.keiyoushiFingerprint),
            sourceIDs: [Self.baoziManhuaSourceID]
        )

        let sources = try ExtensionSourceFactory().makeSources(
            admission: admission,
            transport: NoNetworkTransport(),
            preferences: try InterpretedExtensionPreferences(
                strings: ["BAOZI_BANNER": "0", "CHAPTER_ORDER": "1"],
                booleans: ["QUICK_PAGES": true, "REMOVE_DUPLICATE_IMAGES": false]
            )
        )
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.id, Self.baoziManhuaSourceID)
        XCTAssertEqual(source.name, "包子漫画")
        XCTAssertEqual(source.language, "zh")
        XCTAssertEqual(source.baseURL, "https://cn.baozimh.com")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertFalse(source.getFilterList().isEmpty)
        XCTAssertFalse(source.transportPolicy.allowsInsecureHTTP)
    }

    func testFactoryRejectsFileReplacementBeforeSignatureOrDEXConstruction() throws {
        let bytes = try corpus("batcave")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let admission = try admission(apkBytes: bytes, apkURL: temporary.apk)
        var replaced = bytes
        replaced[replaced.count / 2] ^= 0x01
        try Data(replaced).write(to: temporary.apk, options: .atomic)

        XCTAssertThrowsError(
            try ExtensionSourceFactory().makeSources(
                admission: admission,
                transport: NoNetworkTransport()
            )
        ) {
            XCTAssertEqual($0 as? ExtensionSourceFactoryError, .apkContentMismatch)
        }
    }

    func testFactoryRejectsNonExactSourceIDsBeforeProfileConstruction() throws {
        let bytes = try corpus("batcave")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let nonExactSourceIDSets: [Set<Int64>] = [
            [123],
            [Self.batCaveSourceID, 123],
        ]
        let profileInvalidPreferences = try InterpretedExtensionPreferences(
            strings: ["UNSUPPORTED": "value"]
        )

        for sourceIDs in nonExactSourceIDSets {
            let invalidAdmission = try admission(
                apkBytes: bytes,
                apkURL: temporary.apk,
                sourceIDs: sourceIDs
            )
            XCTAssertThrowsError(
                try ExtensionSourceFactory().makeSources(
                    admission: invalidAdmission,
                    transport: NoNetworkTransport(),
                    preferences: profileInvalidPreferences
                )
            ) {
                XCTAssertEqual(
                    $0 as? ExtensionSourceFactoryError,
                    .sourceIdentityMismatch
                )
            }
        }
    }

    func testAuthenticatedButUnmeasuredExtensionDoesNotExecuteHeuristically() throws {
        let bytes = try corpus("akuma")
        let temporary = try temporaryAPK(bytes)
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = try ExtensionManifest(apkBytes: bytes)
        let versionName = try XCTUnwrap(manifest.versionName)
        let versionCode = try XCTUnwrap(manifest.versionCode)
        let admission = ExtensionAdmission(
            packageName: manifest.packageName,
            versionName: versionName,
            versionCode: versionCode,
            apkPath: temporary.apk.path,
            apkSHA256: APKSignatureVerifier.apkSHA256(bytes),
            signingIdentity: try APKSignatureVerifier().verify(apkBytes: bytes),
            trustSource: .user(fingerprint: Self.keiyoushiFingerprint),
            sourceIDs: [1]
        )

        XCTAssertThrowsError(
            try ExtensionSourceFactory().makeSources(
                admission: admission,
                transport: NoNetworkTransport()
            )
        ) {
            XCTAssertEqual(
                $0 as? ExtensionSourceFactoryError,
                .unsupportedProfile(
                    packageName: manifest.packageName,
                    versionName: versionName
                )
            )
        }
    }
}
