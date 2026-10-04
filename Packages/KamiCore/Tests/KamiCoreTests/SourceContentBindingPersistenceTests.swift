import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)
final class SourceContentBindingPersistenceTests: XCTestCase {
    private let sourceID = SourceContentBindingPersistence.sourceID
    private let package = SourceContentBindingPersistence.packageName
    private let website = "https://Archive.Example/reader"

    private struct Fixture {
        let folder: URL
        let path: String
        let db: SQLiteDatabase
    }

    private func fixture(legacy: Bool = false) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Binding-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("library.sqlite").path
        let db = try SQLiteDatabase(path: path)
        if legacy {
            for version in 1...6 { try db.execute(try XCTUnwrap(Migrations.steps[version])) }
            try db.execute("PRAGMA user_version=6")
        } else { try Migrations.apply(db) }
        return Fixture(folder: folder, path: path, db: db)
    }

    /// Synthetic descriptive evidence, never installed bytes or APK execution.
    @discardableResult
    private func legacyConfiguration(_ f: Fixture, enabled: Bool = false) throws -> InstalledExtensionTrust {
        let schema = try XCTUnwrap(SourceContentBindingPersistence.schema)
        let identity = schema.identity
        let installed = InstalledExtensionTrust(
            packageName: identity.packageName, versionName: identity.versionName,
            versionCode: identity.versionCode, apkPath: f.folder.appendingPathComponent("missing.apk").path,
            apkSHA256: identity.apkSHA256, signatureScheme: .v2,
            currentSigners: [identity.signerFingerprint], signerHistory: [identity.signerFingerprint],
            trustSource: .user(fingerprint: identity.signerFingerprint), sourceIDs: identity.sourceIDs,
            repositoryURL: nil, installedAt: 123, enabled: enabled)
        let signers = String(decoding: try JSONEncoder().encode(installed.currentSigners), as: UTF8.self)
        let sources = String(decoding: try JSONEncoder().encode(installed.sourceIDs.sorted()), as: UTF8.self)
        try f.db.run("""
            INSERT INTO installed_extension(package_name,version_name,version_code,apk_path,apk_sha256,
                signature_scheme,current_signers,signer_history,trust_source,source_ids,installed_at,enabled)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(package), .text(installed.versionName), .int(installed.versionCode), .text(installed.apkPath),
                  .text(installed.apkSHA256), .text(installed.signatureScheme.rawValue), .text(signers), .text(signers),
                  .text(installed.trustSource.persistedValue), .text(sources), .int(123), .bool(enabled)])
        let values = try StoredExtensionPreferenceValues([.baseURL: .string(website), .adult: .boolean(false)]).encoded()
        try f.db.run("""
            INSERT INTO installed_extension_preferences(package_name,identity_fingerprint,schema_revision,revision,user_values)
            VALUES (?,?,?,7,?)
            """, [.text(package), .text(try ExtensionPreferenceBinding.fingerprint(installed)), .int(schema.revision), .text(values)])
        return installed
    }

    @discardableResult
    private func content(_ f: Fixture) throws -> Int64 {
        let id = try f.db.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,'/m','Preserve',0)", [.int(sourceID)])
        let chapter = try f.db.insert("""
            INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read,is_current)
            VALUES (?,'/c','Hidden',1,1,7,0)
            """, [.int(id)])
        try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,123,456)", [.int(id), .int(chapter)])
        return id
    }

    private func seed(_ f: Fixture, url: String?) throws {
        try f.db.run("INSERT INTO source_content_binding(source_id,kind,deployment_url,revision) VALUES (?,?,?,1)",
                     [.int(sourceID), .text(url == nil ? "unresolved" : "deployment"), url.map(SQLiteBindable.text) ?? .null])
    }

    private func assertBindingError(_ db: SQLiteDatabase, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SourceContentBindingPersistence.read(db), file: file, line: line) { error in
            XCTAssertEqual(error as? ExtensionPreferencesError, .invalidContentBinding, file: file, line: line)
        }
    }

    func testSchemaSixUpgradeSeedsKnownContentWithoutReadingAPKOrChangingAuthority() async throws {
        for enabled in [false, true] {
            let f = try fixture(legacy: true)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            let installed = try legacyConfiguration(f, enabled: enabled)
            _ = try content(f)
            let epoch = try f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch")
            let preferences = try f.db.query("SELECT hex(CAST(user_values AS BLOB)) AS value FROM installed_extension_preferences").first?.string("value")
            let store = try LibraryStore(path: f.path)
            let binding = try XCTUnwrap(SourceContentBindingPersistence.read(f.db))
            XCTAssertEqual(binding.kind, .deployment)
            XCTAssertEqual(binding.deploymentURL.map { Data($0.utf8) }, Data(website.utf8))
            XCTAssertEqual(binding.revision, 1)
            XCTAssertEqual(try f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch"), epoch)
            XCTAssertEqual(try f.db.query("PRAGMA user_version").first?.int("user_version"), 7)
            let current = try await store.installedExtensionTrust(packageName: package)
            XCTAssertEqual(current, installed)
            XCTAssertEqual(try f.db.query("SELECT hex(CAST(user_values AS BLOB)) AS value FROM installed_extension_preferences").first?.string("value"), preferences)
            XCTAssertEqual(try f.db.query("SELECT read_duration FROM history").first?.int("read_duration"), 456)
            XCTAssertEqual(try f.db.query("SELECT last_page_read FROM chapter").first?.int("last_page_read"), 7)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.apkPath))
            let backup = try await store.exportBackupSnapshot(exportedAt: 123)
            XCTAssertEqual(backup.sources.first?.contentBinding.deploymentURL, website)
            _ = try LibraryStore(path: f.path)
            XCTAssertEqual(try SourceContentBindingPersistence.read(f.db), binding)
        }
    }

    func testMigrationSeedsValidEmptyConfigurationButDoesNotInferLegacyPreferences() throws {
        for configured in [false, true] {
            let f = try fixture(legacy: true)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            if configured { _ = try legacyConfiguration(f) }
            try f.db.run("INSERT INTO source_preference(source_id,key,value) VALUES (?,'overrideBaseUrl','https://unbound.invalid')", [.int(sourceID)])
            try Migrations.apply(f.db)
            let value = try SourceContentBindingPersistence.read(f.db)
            if configured { XCTAssertEqual(value?.deploymentURL, website) }
            else { XCTAssertNil(value) }
            XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int("n"), 0)
        }
    }

    func testMigrationMakesUnprovenPopulatedNamespacesExplicitlyUnresolved() async throws {
        let corruptions: [String?] = [
            nil,
            "UPDATE installed_extension SET apk_sha256='wrong'",
            "UPDATE installed_extension SET source_ids='[1]'",
            "UPDATE installed_extension SET current_signers='[]'",
            "UPDATE installed_extension SET enabled=2",
            "UPDATE installed_extension_preferences SET schema_revision=99",
            "UPDATE installed_extension_preferences SET user_values=user_values || char(0)",
            "UPDATE installed_extension_preferences SET user_values=CAST(X'C328' AS TEXT)",
            "UPDATE installed_extension_preferences SET revision=zeroblob(20000)",
            "UPDATE installed_extension SET version_code=CAST(zeroblob(20000) AS TEXT)",
        ]
        for sql in corruptions {
            let f = try fixture(legacy: true)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            if sql != nil { _ = try legacyConfiguration(f) }
            _ = try content(f)
            if let sql { try f.db.execute(sql) }
            let store = try LibraryStore(path: f.path)
            let binding = try XCTUnwrap(SourceContentBindingPersistence.read(f.db))
            XCTAssertEqual(binding.kind, .unresolved)
            XCTAssertNil(binding.deploymentURL)
            let backup = try await store.exportBackupSnapshot(exportedAt: 0)
            XCTAssertEqual(backup.sources.first?.contentBinding.kind, .unresolved)
            XCTAssertEqual(backup.manga.first?.history.first?.readDuration, 456)
            XCTAssertEqual(try f.db.query("SELECT is_current FROM chapter").first?.int("is_current"), 0)
        }
    }

    func testLateMigrationFailureRollsBackSeedSchemaAndVersionAndReusesConnection() throws {
        let f = try fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        _ = try legacyConfiguration(f)
        _ = try content(f)
        try f.db.execute("CREATE TRIGGER foo_content_binding_no_relabel AFTER INSERT ON manga BEGIN SELECT 1; END;")
        XCTAssertThrowsError(try Migrations.apply(f.db))
        XCTAssertEqual(try f.db.query("PRAGMA user_version").first?.int("user_version"), 6)
        XCTAssertTrue(try f.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='source_content_binding'").isEmpty)
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM history").first?.int("n"), 1)
        try f.db.execute("DROP TRIGGER foo_content_binding_no_relabel")
        try Migrations.apply(f.db)
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db)?.deploymentURL, website)
    }

    func testMangaIngressAndNamespaceReplacementCannotBypassBindingInvariants() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        XCTAssertThrowsError(try content(f))
        let other = try f.db.insert("INSERT INTO manga(source_id,url) VALUES (7,'/other')")
        XCTAssertThrowsError(try f.db.run("UPDATE manga SET source_id=? WHERE id=?", [.int(sourceID), .int(other)]))
        try seed(f, url: website)
        _ = try content(f)
        for sql in [
            "DELETE FROM source_content_binding",
            "UPDATE source_content_binding SET deployment_url='https://other.invalid',revision=2",
            "UPDATE source_content_binding SET kind='unresolved',deployment_url=NULL,revision=2",
            "INSERT OR REPLACE INTO source_content_binding VALUES (6351052922295965587,'deployment','https://other.invalid',1)",
            "INSERT OR REPLACE INTO source_content_binding VALUES (6351052922295965587,'deployment','\(website)',1)",
        ] { XCTAssertThrowsError(try f.db.execute(sql), sql) }
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db)?.deploymentURL, website)
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM history").first?.int("n"), 1)
    }

    func testEmptyNamespaceStillCannotResetItsRevisionByDeleteOrReplace() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        try seed(f, url: website)
        for sql in ["DELETE FROM source_content_binding",
                    "UPDATE source_content_binding SET revision=1",
                    "INSERT OR REPLACE INTO source_content_binding VALUES (6351052922295965587,'deployment','\(website)',1)"] {
            XCTAssertThrowsError(try f.db.execute(sql))
        }
        let before = try SourceContentBindingPersistence.read(f.db)
        try f.db.execute("BEGIN IMMEDIATE")
        _ = try SourceContentBindingPersistence.save(f.db, expected: before, url: "https://different.invalid")
        try f.db.execute("COMMIT")
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db)?.revision, 2)
    }

    func testKnownBindingSurvivesRemovalOfInstallationAndAllPreferences() async throws {
        let f = try fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        _ = try legacyConfiguration(f)
        _ = try content(f)
        let store = try LibraryStore(path: f.path)
        let binding = try SourceContentBindingPersistence.read(f.db)
        try f.db.run("DELETE FROM installed_extension WHERE package_name=?", [.text(package)])
        XCTAssertTrue(try f.db.query("SELECT * FROM installed_extension_preferences").isEmpty)
        let doc = try await store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(doc.sources.first?.contentBinding.deploymentURL, website)
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db), binding)
        let reopened = try LibraryStore(path: f.path)
        let again = try await reopened.exportBackupSnapshot(exportID: doc.exportID, exportedAt: 0)
        XCTAssertEqual(doc, again)
    }

    func testMalformedBindingFailsBeforeMaterializingUnboundedColumns() throws {
        for assignment in [
            "kind=CAST(X'C328' AS TEXT)", "kind=CAST(zeroblob(20000) AS TEXT)",
            "deployment_url=zeroblob(20000)", "deployment_url=CAST(zeroblob(20000) AS TEXT)",
            "deployment_url=CAST(X'C328' AS TEXT)", "deployment_url=deployment_url || char(0)",
            "deployment_url='http://insecure.invalid'", "deployment_url='https://fixture.invalid/'",
            "kind='unresolved'", "deployment_url=NULL",
            "revision='bad'", "revision=zeroblob(20000)", "revision=0",
        ] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.folder) }
            try seed(f, url: website)
            try f.db.execute("PRAGMA ignore_check_constraints=ON")
            try f.db.execute("DROP TRIGGER foo_content_binding_revision")
            try f.db.execute("UPDATE source_content_binding SET \(assignment)")
            assertBindingError(f.db)
            XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM source_content_binding").first?.int("n"), 1)
        }
    }

    func testMissingBindingWithContentFailsExportRatherThanReinferringSettings() async throws {
        let f = try fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        _ = try legacyConfiguration(f)
        _ = try content(f)
        let store = try LibraryStore(path: f.path)
        try f.db.execute("DROP TRIGGER foo_content_binding_no_delete")
        try f.db.execute("DELETE FROM source_content_binding")
        assertBindingError(f.db)
        do { _ = try await store.exportBackupSnapshot(exportedAt: 0); XCTFail("missing binding accepted") }
        catch { XCTAssertEqual(error as? LibraryBackupSnapshotError, .invalidStoredData) }
        XCTAssertTrue(try f.db.query("SELECT * FROM source_content_binding").isEmpty)
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM installed_extension_preferences").first?.int("n"), 1)
    }

    func testWebsiteByteLimitIsInclusiveAndCannotBeBypassedByMalformedStorage() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let prefix = "https://fixture.invalid/"
        let url = prefix + String(repeating: "a", count: 4096 - prefix.utf8.count)
        let schema = try XCTUnwrap(SourceContentBindingPersistence.schema)
        _ = try schema.validateUserValues([.baseURL: .string(url)])
        try seed(f, url: url)
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db)?.deploymentURL?.utf8.count, 4096)
        XCTAssertThrowsError(try f.db.run("UPDATE source_content_binding SET deployment_url=?,revision=2", [.text(url + "a")]))
        try f.db.execute("PRAGMA ignore_check_constraints=ON")
        try f.db.run("UPDATE source_content_binding SET deployment_url=?,revision=2", [.text(url + "a")])
        assertBindingError(f.db)
    }

    func testBindingSnapshotsDistinguishUnicodeBytesNilAndRevision() {
        let a = SourceContentBindingSnapshot(sourceID: sourceID, kind: .deployment,
            deploymentURL: "https://example.invalid/caf\u{00e9}", revision: 1)
        let b = SourceContentBindingSnapshot(sourceID: sourceID, kind: .deployment,
            deploymentURL: "https://example.invalid/cafe\u{0301}", revision: 1)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.matches(b.deploymentURL!))
        XCTAssertNotEqual(a, .init(sourceID: sourceID, kind: .deployment, deploymentURL: a.deploymentURL, revision: 2))
        XCTAssertNotEqual(a, .init(sourceID: sourceID, kind: .unresolved, deploymentURL: nil, revision: 1))
    }
}
#endif
