import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)

final class ExtensionInstallationServiceTests: XCTestCase {
    private static let sourceID: Int64 = 7_422_099_479_605_463_706
    private static let fingerprint =
        "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"

    private func corpus() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/batcave.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK batcave.apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func extensionEntry() -> ExtensionRepositoryIndex.Extension {
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
                    id: Self.sourceID,
                    name: "BatCave",
                    language: "en",
                    homeURL: "https://batcave.biz"
                ),
            ]
        )
    }

    private func fixture() throws -> (
        directory: URL,
        store: LibraryStore,
        service: ExtensionInstallationService
    ) {
        let bytes = try corpus()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kami-ExtensionInstallationTests-\(UUID().uuidString)", isDirectory: true)
        let store = try LibraryStore(inMemory: true)
        let admission = ExtensionAdmissionService(store: store)
        let service = ExtensionInstallationService(
            store: store,
            admissionService: admission,
            rootDirectory: directory,
            downloadAPK: { _ in bytes }
        )
        return (directory, store, service)
    }

    func testRepositoryKeyCompletesAtomicDurableInstallWithoutUserPrompt() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.service.beginInstall(
            extension: extensionEntry(),
            repositoryURL: "https://example.invalid/index.pb",
            repositorySigningKey: Self.fingerprint
        )
        guard case let .installed(admission) = outcome else {
            return XCTFail("repository signer should complete the install")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: admission.apkPath))
        XCTAssertEqual(
            URL(fileURLWithPath: admission.apkPath).deletingLastPathComponent(),
            fixture.directory.standardizedFileURL
        )
        let persisted = try await fixture.store.installedExtensionTrust(
            packageName: admission.packageName
        )
        XCTAssertEqual(persisted?.enabled, true)
        XCTAssertEqual(persisted?.apkPath, admission.apkPath)
        XCTAssertEqual(persisted?.apkSHA256, admission.apkSHA256)
    }

    func testLegacyRepositoryRequiresExactDisplayedSignerConfirmation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.service.beginInstall(
            extension: extensionEntry(),
            repositoryURL: "https://example.invalid/index.min.json",
            repositorySigningKey: nil
        )
        guard case let .requiresUserTrust(preparation) = outcome else {
            return XCTFail("legacy first install must require signer confirmation")
        }
        XCTAssertEqual(preparation.currentSignerFingerprints, [Self.fingerprint])
        let beforeConfirmation = try await fixture.store.installedExtensionTrust(
            packageName: preparation.packageName
        )
        XCTAssertNil(beforeConfirmation)

        let admission = try await fixture.service.confirmUserTrust(
            preparation,
            fingerprint: Self.fingerprint
        )
        XCTAssertEqual(
            admission.trustSource,
            .user(fingerprint: Self.fingerprint)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: admission.apkPath))
    }

    func testCancelledLegacyConfirmationDoesNotPersistTrust() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await fixture.service.beginInstall(
            extension: extensionEntry(),
            repositoryURL: "https://example.invalid/index.min.json",
            repositorySigningKey: nil
        )
        guard case let .requiresUserTrust(preparation) = outcome else {
            return XCTFail("expected pending signer confirmation")
        }
        await fixture.service.cancel(preparation)
        let persisted = try await fixture.store.installedExtensionTrust(
            packageName: preparation.packageName
        )
        XCTAssertNil(persisted)
        do {
            _ = try await fixture.service.confirmUserTrust(
                preparation,
                fingerprint: Self.fingerprint
            )
            XCTFail("cancelled preparation must not be reusable")
        } catch let error as ExtensionInstallationError {
            XCTAssertEqual(error, .pendingInstallExpired)
        }
    }
}

#endif
