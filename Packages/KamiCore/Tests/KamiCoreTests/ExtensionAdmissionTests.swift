import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)

final class ExtensionAdmissionTests: XCTestCase {
    private let keiyoushiFingerprint =
        "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private let aospFirstFingerprint =
        "fb5dbd3c669af9fc236c6991e6387b7f11ff0590997f22d0f5c74ff40e04fca8"

    private struct DummySource: KamiSource {
        let id: Int64
        let name = "Admitted test source"
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

    private func corpus(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/KamiCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KamiCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func batCaveExtension(sourceID: Int64 = 812_345) -> ExtensionRepositoryIndex.Extension {
        ExtensionRepositoryIndex.Extension(
            name: "BatCave",
            packageName: "eu.kanade.tachiyomi.extension.en.batcave",
            versionName: "1.6.9",
            versionCode: 9,
            extensionLib: "1.6",
            contentWarning: .safe,
            apkURL: "https://example.invalid/batcave.apk",
            sources: [
                ExtensionRepositoryIndex.Source(
                    id: sourceID,
                    name: "BatCave",
                    language: "en",
                    homeURL: "https://batcave.biz"
                ),
            ]
        )
    }

    func testRepositorySignerTrustIsPersistedBeforeDownloadedRegistration() async throws {
        let sourceID: Int64 = 812_345
        let store = try LibraryStore(inMemory: true)
        let service = ExtensionAdmissionService(store: store)
        let repoURL = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"
        let admission = try await service.admit(
            apkBytes: corpus("batcave"),
            extension: batCaveExtension(sourceID: sourceID),
            apkPath: "/private/extensions/batcave.apk",
            repositoryURL: repoURL,
            repositorySigningKey: keiyoushiFingerprint
        )

        XCTAssertEqual(admission.signingIdentity.scheme, .v2)
        XCTAssertEqual(admission.trustSource, .repository(url: repoURL))
        XCTAssertEqual(admission.sourceIDs, [sourceID])
        let persisted = try await store.installedExtensionTrust(
            packageName: admission.packageName
        )
        XCTAssertEqual(persisted?.currentSigners, [keiyoushiFingerprint])
        XCTAssertEqual(persisted?.apkSHA256, admission.apkSHA256)
        XCTAssertEqual(persisted?.trustSource, admission.trustSource)

        try await MainActor.run {
            let registry = SourceRegistry()
            let initialCount = registry.sources.count
            try registry.addDownloaded(DummySource(id: sourceID), admission: admission)
            XCTAssertEqual(registry.sources.count, initialCount + 1)
            XCTAssertThrowsError(
                try registry.addDownloaded(DummySource(id: sourceID + 1), admission: admission)
            ) {
                XCTAssertEqual(
                    $0 as? ExtensionAdmissionError,
                    .sourceNotDeclared(sourceID + 1)
                )
            }
        }
    }

    func testInitialInstallRejectsWrongSignerAndAllowsExactExplicitTrust() async throws {
        let apk = try corpus("batcave")
        let wrongStore = try LibraryStore(inMemory: true)
        let wrongService = ExtensionAdmissionService(store: wrongStore)
        do {
            _ = try await wrongService.admit(
                apkBytes: apk,
                extension: batCaveExtension(),
                apkPath: "/private/extensions/batcave.apk",
                repositorySigningKey: aospFirstFingerprint
            )
            XCTFail("wrong repository signer must not be admitted")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .untrustedSigner([keiyoushiFingerprint]))
        }

        let userStore = try LibraryStore(inMemory: true)
        let userService = ExtensionAdmissionService(store: userStore)
        let admission = try await userService.admit(
            apkBytes: apk,
            extension: batCaveExtension(),
            apkPath: "/private/extensions/batcave.apk",
            explicitUserTrustFingerprint: keiyoushiFingerprint
        )
        XCTAssertEqual(admission.trustSource, .user(fingerprint: keiyoushiFingerprint))
    }

    func testUpdatesRequireVersionMonotonicityAndVerifiedSignerContinuity() async throws {
        let verifier = APKSignatureVerifier()
        let originalBytes = try corpus("aosp-v3-original")
        let rotatedBytes = try corpus("aosp-v3-lineage")
        let original = try verifier.verify(apkBytes: originalBytes)
        let rotated = try verifier.verify(apkBytes: rotatedBytes)
        let unrelated = try verifier.verify(apkBytes: corpus("batcave"))
        let store = try LibraryStore(inMemory: true)

        let first = ExtensionAdmissionCandidate(
            packageName: "example.rotating.extension",
            versionName: "1.0",
            versionCode: 1,
            apkPath: "/private/extensions/rotating.apk",
            apkSHA256: APKSignatureVerifier.apkSHA256(originalBytes),
            signingIdentity: original,
            presentedTrustSource: .user(fingerprint: aospFirstFingerprint),
            repositoryURL: nil,
            sourceIDs: [77]
        )
        _ = try await store.commitExtensionAdmission(first)

        let update = ExtensionAdmissionCandidate(
            packageName: first.packageName,
            versionName: "2.0",
            versionCode: 2,
            apkPath: first.apkPath,
            apkSHA256: APKSignatureVerifier.apkSHA256(rotatedBytes),
            signingIdentity: rotated,
            presentedTrustSource: nil,
            repositoryURL: nil,
            sourceIDs: first.sourceIDs
        )
        let admittedUpdate = try await store.commitExtensionAdmission(update)
        XCTAssertEqual(admittedUpdate.signingIdentity.signers[0].certificateHistory.count, 2)
        XCTAssertEqual(
            admittedUpdate.trustSource,
            .user(fingerprint: aospFirstFingerprint)
        )

        let wrong = ExtensionAdmissionCandidate(
            packageName: update.packageName,
            versionName: "3.0",
            versionCode: 3,
            apkPath: update.apkPath,
            apkSHA256: APKSignatureVerifier.apkSHA256(try corpus("batcave")),
            signingIdentity: unrelated,
            presentedTrustSource: .repository(url: "https://attacker.invalid"),
            repositoryURL: "https://attacker.invalid",
            sourceIDs: update.sourceIDs
        )
        do {
            _ = try await store.commitExtensionAdmission(wrong)
            XCTFail("unrelated signer must not replace persisted trust")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .updateSignerMismatch)
        }

        let downgrade = ExtensionAdmissionCandidate(
            packageName: update.packageName,
            versionName: "1.0",
            versionCode: 1,
            apkPath: update.apkPath,
            apkSHA256: update.apkSHA256,
            signingIdentity: rotated,
            presentedTrustSource: nil,
            repositoryURL: nil,
            sourceIDs: update.sourceIDs
        )
        do {
            _ = try await store.commitExtensionAdmission(downgrade)
            XCTFail("downgrade must be rejected")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .downgrade(installed: 2, candidate: 1))
        }

        let replacedSameVersion = ExtensionAdmissionCandidate(
            packageName: update.packageName,
            versionName: update.versionName,
            versionCode: update.versionCode,
            apkPath: update.apkPath,
            apkSHA256: String(repeating: "0", count: 64),
            signingIdentity: rotated,
            presentedTrustSource: nil,
            repositoryURL: nil,
            sourceIDs: update.sourceIDs
        )
        do {
            _ = try await store.commitExtensionAdmission(replacedSameVersion)
            XCTFail("same-version replacement must be rejected")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .sameVersionContentMismatch)
        }
    }
}

#endif
