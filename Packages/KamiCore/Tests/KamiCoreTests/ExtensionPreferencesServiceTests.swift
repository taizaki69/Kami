import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)

final class ExtensionPreferencesServiceTests: XCTestCase {
    private static let package = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let sourceID: Int64 = 6_351_052_922_295_965_587
    private static let signer = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
    private static let baseURL = "https://foolslide.example"
    private typealias Field = InterpretedExtensionPreferenceSchema.FieldID
    private typealias Value = InterpretedExtensionPreferenceSchema.Value

    private struct Fixture {
        let directory: URL
        let apk: URL
        let path: String
        let bytes: [UInt8]
        let store: LibraryStore
        let admission: ExtensionAdmissionService
        let preferences: ExtensionPreferencesService
    }

    private actor PageTransport: CompatHTTPTransport {
        nonisolated let sourceID = "persisted-foo-fixture"
        private var requests: [CompatHTTPRequest] = []
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return CompatHTTPResponse(
                finalURL: request.url, statusCode: 200,
                headers: [.init(name: "Content-Type", value: "text/html; charset=utf-8")],
                body: Array(#"<div id="chapter"><script>var pages = [{"url":"/images/001.jpg"}];</script></div>"#.utf8)
            )
        }
        func captured() -> [CompatHTTPRequest] { requests }
    }

    private struct RefreshSource: KamiSource {
        let id: Int64
        let name = "Offline refresh"
        let language = "en"
        let baseURL = "https://fixture.invalid"
        func getPopularManga(page: Int) async throws -> MangasPageCompat { .init(mangas: [], hasNextPage: false) }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            try await getPopularManga(page: page)
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { manga }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { [] }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
        func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
            var updated = manga
            updated.title = "Refreshed"
            updated.altTitles = ["Refreshed alias"]
            return .init(manga: updated, chapters: [.init(url: "/refreshed-chapter", name: "Refreshed chapter")])
        }
    }

    private func corpus(_ name: String = "measurement/foolslidecustomizable") throws -> [UInt8] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [UInt8](try Data(contentsOf: root.appendingPathComponent("Tests/corpus/\(name).apk")))
    }

    private func entry(sourceIDs: [Int64]? = nil) -> ExtensionRepositoryIndex.Extension {
        .init(
            name: "FoolSlide Customizable", packageName: Self.package,
            versionName: "1.6.6", versionCode: 6, extensionLib: "1.6", contentWarning: .mixed,
            apkURL: "https://fixtures.example/extension.apk",
            sources: (sourceIDs ?? [Self.sourceID]).map {
                .init(id: $0, name: "FoolSlide Customizable", language: "other", homeURL: "https://127.0.0.1")
            }
        )
    }

    private func fixture(enabled: Bool = false, sourceIDs: [Int64]? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Preferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apk = directory.appendingPathComponent("extension.apk")
        let bytes = try corpus()
        try Data(bytes).write(to: apk, options: .atomic)
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        let admission = ExtensionAdmissionService(store: store)
        _ = try await admission.admit(
            apkBytes: bytes, extension: entry(sourceIDs: sourceIDs), apkPath: apk.path,
            repositoryURL: "https://fixtures.example/index.pb", repositorySigningKey: Self.signer
        )
        try await store.setExtensionEnabled(enabled, packageName: Self.package)
        return Fixture(directory: directory, apk: apk, path: path, bytes: bytes, store: store,
                       admission: admission, preferences: ExtensionPreferencesService(store: store))
    }

    private func values(url: String = "https://foolslide.example", adult: Bool = false) -> [Field: Value] {
        [.baseURL: .string(url), .adult: .boolean(adult)]
    }

    private func save(_ fixture: Fixture, adult: Bool = false) async throws -> ExtensionConfigurationSnapshot {
        let snapshot = try await fixture.preferences.configuration(packageName: Self.package)
        return try await fixture.preferences.saveConfiguration(snapshot: snapshot, userValues: values(adult: adult))
    }

    private func expect(_ expected: ExtensionPreferencesError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ExtensionPreferencesError, expected)
        }
    }

    private func execution(_ fixture: Fixture) async throws -> ExtensionExecutionConfiguration {
        let admission = try await fixture.admission.restore(packageName: Self.package)
        return try await fixture.preferences.loadForExecution(admission: admission)
    }

    func testDisabledConfigurationSurvivesReopeningWithoutIssuingExecutableAdmission() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let empty = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertFalse(empty.enabled)
        XCTAssertEqual(empty.revision, 0)
        XCTAssertEqual(empty.userValues, [.adult: .boolean(true)])
        let saved = try await save(f)
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.userValues, values())
        let reopened = try LibraryStore(path: f.path)
        let restored = try await ExtensionPreferencesService(store: reopened).configuration(packageName: Self.package)
        XCTAssertEqual(restored, saved)
        let raw = try SQLiteDatabase(path: f.path).query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values") ?? ""
        XCTAssertFalse(raw.contains("defaultBaseUrl"))
        XCTAssertFalse(raw.contains("trust_source"))
        do {
            _ = try await ExtensionAdmissionService(store: reopened).restore(packageName: Self.package)
            XCTFail("configuration must not enable an installation")
        } catch let error as ExtensionAdmissionError {
            XCTAssertEqual(error, .extensionDisabled(Self.package))
        }
    }

    func testSchemaTwoMigrationPreservesTrustAndReaderDataWithoutImportingLegacyPreferences() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let installed = try await f.store.installedExtensionTrust(packageName: Self.package)
        let trust = try XCTUnwrap(installed)
        let legacyPath = f.directory.appendingPathComponent("schema-two.sqlite").path
        let legacy = try SQLiteDatabase(path: legacyPath)
        try legacy.execute(try XCTUnwrap(Migrations.steps[1]))
        try legacy.execute(try XCTUnwrap(Migrations.steps[2]))
        try legacy.execute("PRAGMA user_version=2")
        let signers = String(decoding: try JSONEncoder().encode(trust.currentSigners), as: UTF8.self)
        let history = String(decoding: try JSONEncoder().encode(trust.signerHistory), as: UTF8.self)
        let ids = String(decoding: try JSONEncoder().encode(trust.sourceIDs.sorted()), as: UTF8.self)
        try legacy.run("""
            INSERT INTO installed_extension
                (package_name,version_name,version_code,apk_path,installed_at,enabled,
                 apk_sha256,signature_scheme,current_signers,signer_history,trust_source,source_ids,repo_url)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(trust.packageName), .text(trust.versionName), .int(trust.versionCode),
                  .text(trust.apkPath), .int(trust.installedAt), .bool(trust.enabled), .text(trust.apkSHA256),
                  .text(trust.signatureScheme.rawValue), .text(signers), .text(history),
                  .text(trust.trustSource.persistedValue), .text(ids), trust.repositoryURL.map(SQLiteBindable.text) ?? .null])
        let mangaID = try legacy.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,?,?,1)",
                                       [.int(Self.sourceID), .text("/existing"), .text("Keep")])
        let chapterID = try legacy.insert("INSERT INTO chapter(manga_id,url,name,read,last_page_read) VALUES (?,?,?,1,7)",
                                         [.int(mangaID), .text("/chapter"), .text("Keep chapter")])
        try legacy.run("INSERT INTO history(manga_id,chapter_id,last_read) VALUES (?,?,77)", [.int(mangaID), .int(chapterID)])
        try legacy.run("INSERT INTO source_preference(source_id,key,value) VALUES (?,?,?)",
                       [.int(Self.sourceID), .text("overrideBaseUrl"), .text("https://unbound.example")])
        let migrated = try LibraryStore(path: legacyPath)
        XCTAssertEqual(try legacy.query("PRAGMA user_version").first?.int("user_version"), 3)
        let currentTrust = try await migrated.installedExtensionTrust(packageName: Self.package)
        XCTAssertEqual(currentTrust, trust)
        let snapshot = try await ExtensionPreferencesService(store: migrated).configuration(packageName: Self.package)
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertNil(snapshot.userValues[.baseURL])
        let manga = try await migrated.manga(id: mangaID)
        let chapters = try await migrated.chapters(mangaId: mangaID)
        let restoredHistory = try await migrated.history()
        XCTAssertEqual(manga?.inLibrary, true)
        XCTAssertEqual(chapters.first?.lastPageRead, 7)
        XCTAssertEqual(restoredHistory.map { $0.2 }, [77])
        XCTAssertEqual(try legacy.query("SELECT value FROM source_preference").first?.string("value"), "https://unbound.example")
    }

    func testEnabledFooWithoutSavedConfigurationCannotLoadExecutionValues() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let admitted = try await f.admission.restore(packageName: Self.package)
        await expect(.configurationRequired) { _ = try await f.preferences.loadForExecution(admission: admitted) }
    }

    func testRestoredPreferencesDriveExactAdultRequestsAfterExplicitEnable() async throws {
        for adult in [false, true] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await save(f, adult: adult)
            let reopened = try LibraryStore(path: f.path)
            try await reopened.setExtensionEnabled(true, packageName: Self.package)
            let admission = try await ExtensionAdmissionService(store: reopened).restore(packageName: Self.package)
            let service = ExtensionPreferencesService(store: reopened)
            let configuration = try await service.loadForExecution(admission: admission)
            let transport = PageTransport()
            let source = try XCTUnwrap(ExtensionSourceFactory().makeSources(
                admission: admission, transport: transport, preferences: configuration.runtimePreferences
            ).first)
            try await service.verifyCurrentExecution(configuration)
            XCTAssertEqual(source.baseURL, Self.baseURL)
            let pages = try await source.getPageList(chapter: .init(url: "/read/alpha/en/0/1/", name: "Chapter"))
            XCTAssertEqual(pages.map(\.imageURL), [Self.baseURL + "/images/001.jpg"])
            let requests = await transport.captured()
            XCTAssertEqual(requests.map(\.url), [Self.baseURL + "/read/alpha/en/0/1/"])
            XCTAssertEqual(requests.map(\.method), [adult ? "POST" : "GET"])
            XCTAssertEqual(requests.first?.body, adult ? .form(fields: [.init(name: "adult", value: "true")]) : nil)
        }
    }

    func testInvalidSaveLeavesSettingsTrustAndEnablementIntactWithoutEchoingURL() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let trust = try await f.store.installedExtensionTrust(packageName: Self.package)
        let invalid: [[Field: Value]] = [
            [.adult: .boolean(false)], values(url: "https://user:secret@private.example"),
            values(url: "https://foolslide.example/#secret"), values(url: "https://foolslide.example/"),
            [.baseURL: .boolean(true)], [.baseURL: .string(Self.baseURL), .adult: .string("true")],
        ]
        for input in invalid {
            do {
                _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: input)
                XCTFail("invalid settings should fail")
            } catch {
                XCTAssertNotNil(error as? InterpretedExtensionPreferenceError)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("private.example"))
            }
            let current = try await f.preferences.configuration(packageName: Self.package)
            let currentTrust = try await f.store.installedExtensionTrust(packageName: Self.package)
            XCTAssertEqual(current, saved)
            XCTAssertEqual(currentTrust, trust)
        }
    }

    func testSaveReauthenticatesTamperedOrMissingAPKAndPreservesDocument() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let db = try SQLiteDatabase(path: f.path)
        let before = try db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values")
        var changed = f.bytes
        changed[changed.count / 2] ^= 1
        try Data(changed).write(to: f.apk, options: .atomic)
        await expect(.authenticationFailed) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(adult: true))
        }
        await expect(.authenticationFailed) { _ = try await f.preferences.configuration(packageName: Self.package) }
        try FileManager.default.removeItem(at: f.apk)
        await expect(.authenticationFailed) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(adult: true))
        }
        XCTAssertEqual(try db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values"), before)
    }

    func testRepositorySourceIDsCannotManufactureASettingsContract() async throws {
        let f = try await fixture(sourceIDs: [Self.sourceID, 999])
        defer { try? FileManager.default.removeItem(at: f.directory) }
        await expect(.authenticationFailed) { _ = try await f.preferences.configuration(packageName: Self.package) }
        XCTAssertTrue(try SQLiteDatabase(path: f.path).query("SELECT * FROM installed_extension_preferences").isEmpty)
    }

    func testStaleDocumentAndInstallationSnapshotsCannotOverwriteCurrentState() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await save(f)
        let second = try await f.preferences.saveConfiguration(snapshot: first, userValues: values(adult: true))
        await expect(.staleConfiguration) {
            _ = try await f.preferences.saveConfiguration(snapshot: first, userValues: self.values(adult: false))
        }
        try await f.store.setExtensionEnabled(true, packageName: Self.package)
        await expect(.staleInstallation) {
            _ = try await f.preferences.saveConfiguration(snapshot: second, userValues: self.values(adult: false))
        }
        let current = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertTrue(current.enabled)
        XCTAssertEqual(current.revision, second.revision)
        XCTAssertEqual(current.userValues, second.userValues)
    }

    func testAnyPersistedMangaBlocksDeploymentChangeButAllowsAdultChange() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let id = try await f.store.upsert(Manga(sourceId: Self.sourceID, url: "/relative", title: "Keep", inLibrary: false))
        try await f.store.replaceChapters(mangaId: id, with: [.init(mangaId: id, url: "/chapter", name: "Read", read: true, bookmark: true, lastPageRead: 7)])
        let chapters = try await f.store.chapters(mangaId: id)
        let chapterID = try XCTUnwrap(chapters.first?.id)
        try await f.store.recordHistory(mangaId: id, chapterId: chapterID)
        await expect(.deploymentInUse) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(url: "https://different.example"))
        }
        let changed = try await f.preferences.saveConfiguration(snapshot: saved, userValues: values(adult: true))
        XCTAssertEqual(changed.userValues[.baseURL], .string(Self.baseURL))
        let after = try await f.store.manga(id: id)
        let afterChapters = try await f.store.chapters(mangaId: id)
        let history = try await f.store.history()
        XCTAssertEqual(after?.title, "Keep")
        XCTAssertEqual(after?.inLibrary, false)
        XCTAssertEqual(afterChapters, chapters)
        XCTAssertEqual(history.map { $0.1.id }, [chapterID])
    }

    func testMangaInsertedAfterSnapshotIsCheckedInsideSaveTransaction() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let other = try LibraryStore(path: f.path)
        _ = try await other.upsert(Manga(sourceId: Self.sourceID, url: "/arrived-later", inLibrary: false))
        await expect(.deploymentInUse) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(url: "https://different.example"))
        }
        let unchanged = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertEqual(unchanged, saved)
    }

    func testMissingDeploymentBindingWithExistingMangaCannotBeRetargeted() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let draft = try await f.preferences.configuration(packageName: Self.package)
        _ = try await f.store.upsert(Manga(sourceId: Self.sourceID, url: "/legacy-relative"))
        await expect(.deploymentInUse) {
            _ = try await f.preferences.saveConfiguration(snapshot: draft, userValues: self.values())
        }
        let current = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertEqual(current.revision, 0)
    }

    func testOtherSourcesDoNotLockTheInitialDeployment() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.store.upsert(Manga(sourceId: 999, url: "/other"))
        let saved = try await save(f)
        XCTAssertEqual(saved.revision, 1)
    }

    func testCorruptOrUnboundedStoredDocumentsFailClosed() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await save(f)
        let db = try SQLiteDatabase(path: f.path)
        let original = try XCTUnwrap(db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values"))
        let malformed = [
            "not json", "{}",
            #"{"strings":{"overrideBaseUrl":"https://foolslide.example"},"booleans":{}}"#,
            #"{"strings":{"overrideBaseUrl":"https://foolslide.example","defaultBaseUrl":"https://127.0.0.1"},"booleans":{"adult":false}}"#,
            #"{"strings":{"overrideBaseUrl":"https://foolslide.example","adult":"false"},"booleans":{"adult":false}}"#,
            #"{"strings":{"overrideBaseUrl":"https://foolslide.example"},"booleans":{"adult":1}}"#,
            #"{"strings":{"overrideBaseUrl":"https://foolslide.example"},"booleans":{"adult":false},"secret":"ignored"}"#,
        ]
        for payload in malformed {
            try db.run("UPDATE installed_extension_preferences SET user_values=?", [.text(payload)])
            await expect(.invalidStoredConfiguration) { _ = try await f.preferences.configuration(packageName: Self.package) }
        }
        try db.run("UPDATE installed_extension_preferences SET user_values=?, schema_revision=2", [.text(original)])
        await expect(.invalidStoredConfiguration) { _ = try await f.preferences.configuration(packageName: Self.package) }
        try db.run("UPDATE installed_extension_preferences SET schema_revision=1,identity_fingerprint=?", [.text(String(repeating: "0", count: 64))])
        await expect(.invalidStoredConfiguration) { _ = try await f.preferences.configuration(packageName: Self.package) }
        let installed = try await f.store.installedExtensionTrust(packageName: Self.package)
        let fingerprint = try ExtensionPreferenceBinding.fingerprint(try XCTUnwrap(installed))
        try db.run("UPDATE installed_extension_preferences SET identity_fingerprint=?", [.text(fingerprint)])
        do {
            try db.run("UPDATE installed_extension_preferences SET user_values=?", [.text(String(repeating: "漫", count: 6_000))])
            XCTFail("SQLite CHECK must count UTF-8 bytes")
        } catch is SQLiteDatabase.SQLiteError {}
        try db.execute("PRAGMA ignore_check_constraints=ON")
        try db.run("UPDATE installed_extension_preferences SET user_values=?", [.text(String(repeating: "x", count: 32_768))])
        await expect(.invalidStoredConfiguration) { _ = try await f.preferences.configuration(packageName: Self.package) }
        try db.run("UPDATE installed_extension_preferences SET user_values=?", [.blob([0, 1, 2])])
        await expect(.invalidStoredConfiguration) { _ = try await f.preferences.configuration(packageName: Self.package) }
    }

    func testSQLiteSaveFailurePreservesPreviousDocumentAndTrust() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let trust = try await f.store.installedExtensionTrust(packageName: Self.package)
        let db = try SQLiteDatabase(path: f.path)
        try db.execute("""
            CREATE TRIGGER fail_settings BEFORE UPDATE ON installed_extension_preferences
            BEGIN SELECT RAISE(ABORT, 'private fixture failure'); END;
            """)
        await expect(.storageUnavailable) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(adult: true))
        }
        let current = try await f.preferences.configuration(packageName: Self.package)
        let currentTrust = try await f.store.installedExtensionTrust(packageName: Self.package)
        XCTAssertEqual(current, saved)
        XCTAssertEqual(currentTrust, trust)
    }

    func testExactReadmissionPreservesDocumentAndIdentityChangeInvalidatesAtomically() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        _ = try await f.admission.admit(apkBytes: f.bytes, extension: entry(), apkPath: f.apk.path)
        let repeated = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertEqual(repeated.userValues, saved.userValues)
        XCTAssertEqual(repeated.revision, saved.revision)
        XCTAssertFalse(repeated.enabled)
        let before = try await f.store.installedExtensionTrust(packageName: Self.package)
        let db = try SQLiteDatabase(path: f.path)
        try db.execute("""
            CREATE TRIGGER fail_installation BEFORE UPDATE ON installed_extension
            WHEN NEW.source_ids != OLD.source_ids
            BEGIN SELECT RAISE(ABORT, 'fixture install failure after preference deletion'); END;
            """)
        do {
            _ = try await f.admission.admit(apkBytes: f.bytes, extension: entry(sourceIDs: [Self.sourceID, 999]), apkPath: f.apk.path)
            XCTFail("fixture update must fail")
        } catch is SQLiteDatabase.SQLiteError {}
        let rollback = try await f.preferences.configuration(packageName: Self.package)
        let rollbackTrust = try await f.store.installedExtensionTrust(packageName: Self.package)
        XCTAssertEqual(rollback.userValues, saved.userValues)
        XCTAssertEqual(rollback.revision, saved.revision)
        XCTAssertEqual(rollbackTrust, before)
        try db.execute("DROP TRIGGER fail_installation")
        _ = try await f.admission.admit(apkBytes: f.bytes, extension: entry(sourceIDs: [Self.sourceID, 999]), apkPath: f.apk.path)
        XCTAssertTrue(try db.query("SELECT * FROM installed_extension_preferences").isEmpty)
        let changed = try await f.store.installedExtensionTrust(packageName: Self.package)
        XCTAssertEqual(changed?.sourceIDs, [Self.sourceID, 999])
        XCTAssertEqual(changed?.enabled, false)
        await expect(.staleInstallation) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values())
        }
    }

    func testFailedAdmissionAndRepositoryRemovalPreserveConfiguration() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        var changed = f.bytes
        changed[changed.count / 2] ^= 1
        do {
            _ = try await f.admission.admit(apkBytes: changed, extension: entry(), apkPath: f.apk.path)
            XCTFail("tampered update must fail before durable changes")
        } catch is APKSignatureVerificationError {}
        _ = try await f.store.upsertExtensionRepository(url: "https://fixtures.example/index.pb", name: "Fixture", signingKey: Self.signer)
        try await f.store.removeExtensionRepository(url: "https://fixtures.example/index.pb")
        let after = try await f.preferences.configuration(packageName: Self.package)
        XCTAssertEqual(after, saved)
    }

    func testExecutionConfigurationBecomesStaleOnSaveAndDisable() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let old = try await execution(f)
        try await f.preferences.verifyCurrentExecution(old)
        _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: values(adult: true))
        await expect(.staleConfiguration) { try await f.preferences.verifyCurrentExecution(old) }
        let current = try await execution(f)
        try await f.store.setExtensionEnabled(false, packageName: Self.package)
        await expect(.staleInstallation) { try await f.preferences.verifyCurrentExecution(current) }
    }

    func testOldResultAfterDeploymentSaveCannotPersistRelativeURLs() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let old = try await execution(f)
        _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: values(url: "https://new.example"))
        await expect(.staleConfiguration) {
            _ = try await f.store.persistSourceUpdate(
                manga: Manga(sourceId: Self.sourceID, url: "/late"),
                chapters: [.init(url: "/late/chapter", name: "Late")], expectedConfiguration: old
            )
        }
        let late = try await f.store.manga(sourceId: Self.sourceID, url: "/late")
        XCTAssertNil(late)
        XCTAssertTrue(try SQLiteDatabase(path: f.path).query("SELECT * FROM chapter").isEmpty)
    }

    func testSourceResultBeforeDeploymentSaveLocksURLAndPreservesReaderStateOnRefresh() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let current = try await execution(f)
        let result = try await f.store.persistSourceUpdate(
            manga: Manga(sourceId: Self.sourceID, url: "/persisted", title: "Original"),
            chapters: [.init(url: "/chapter", name: "Original chapter")], expectedConfiguration: current
        )
        await expect(.deploymentInUse) {
            _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: self.values(url: "https://new.example"))
        }
        let id = try XCTUnwrap(result.manga.id)
        let chapterID = try XCTUnwrap(result.chapters.first?.id)
        try await f.store.setLibrary(true, mangaId: id)
        try await f.store.markRead(true, chapterId: chapterID)
        try await f.store.updateProgress(chapterId: chapterID, page: 7)
        try await f.store.recordHistory(mangaId: id, chapterId: chapterID)
        var refreshed = result.manga
        refreshed.title = "Updated"
        refreshed.inLibrary = false
        let update = try await f.store.persistSourceUpdate(
            manga: refreshed, chapters: [.init(url: "/chapter", name: "Updated chapter")], expectedConfiguration: current
        )
        XCTAssertEqual(update.manga.id, id)
        XCTAssertTrue(update.manga.inLibrary)
        XCTAssertEqual(update.manga.title, "Updated")
        XCTAssertEqual(update.chapters.first?.id, chapterID)
        XCTAssertEqual(update.chapters.first?.lastPageRead, 7)
        XCTAssertEqual(update.chapters.first?.read, true)
        let history = try await f.store.history()
        XCTAssertEqual(history.map { $0.1.id }, [chapterID])
    }

    func testSourceWriteRequiresCorrectTokenAndCannotSpoofAnExistingMangaID() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await save(f)
        let configuration = try await execution(f)
        for (sourceID, token) in [(Self.sourceID, Optional<ExtensionExecutionConfiguration>.none), (Int64(999), configuration)] {
            do {
                _ = try await f.store.persistSourceUpdate(manga: Manga(sourceId: sourceID, url: "/bad"), chapters: [], expectedConfiguration: token)
                XCTFail("unscoped/source-mismatched write must fail")
            } catch is SourceUpdatePersistenceError {}
        }
        let native = try await f.store.persistSourceUpdate(
            manga: Manga(sourceId: MangaDexSource().id, url: "native", title: "Native"), chapters: [], expectedConfiguration: nil
        )
        do {
            _ = try await f.store.persistSourceUpdate(
                manga: Manga(id: native.manga.id, sourceId: Self.sourceID, url: "/spoof", title: "Spoof"),
                chapters: [], expectedConfiguration: configuration
            )
            XCTFail("an admitted source cannot change another source's manga")
        } catch let error as SourceUpdatePersistenceError {
            XCTAssertEqual(error, .sourceIdentityMismatch)
        }
        let intact = try await f.store.manga(id: try XCTUnwrap(native.manga.id))
        XCTAssertEqual(intact?.title, "Native")
    }

    func testSourceWriteFailureRollsBackMangaAndChaptersTogether() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await save(f)
        let configuration = try await execution(f)
        let db = try SQLiteDatabase(path: f.path)
        try db.execute("""
            CREATE TRIGGER fail_chapter BEFORE INSERT ON chapter
            BEGIN SELECT RAISE(ABORT, 'fixture failure after manga write'); END;
            """)
        do {
            _ = try await f.store.persistSourceUpdate(
                manga: Manga(sourceId: Self.sourceID, url: "/atomic", title: "Atomic"),
                chapters: [.init(url: "/chapter", name: "Chapter")], expectedConfiguration: configuration
            )
            XCTFail("fixture chapter write must fail")
        } catch is SQLiteDatabase.SQLiteError {}
        let absent = try await f.store.manga(sourceId: Self.sourceID, url: "/atomic")
        XCTAssertNil(absent)
        XCTAssertTrue(try db.query("SELECT * FROM chapter").isEmpty)
    }

    func testLibraryServiceNativeRefreshPersistsMetadataAndChaptersTogether() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let native = MangaDexSource().id
        let id = try await f.store.upsert(Manga(sourceId: native, url: "native", title: "Original", inLibrary: true))
        let result = try await LibraryService(store: f.store).refresh(mangaId: id, source: RefreshSource(id: native))
        let chapters = try await f.store.chapters(mangaId: id)
        XCTAssertEqual(result?.title, "Refreshed")
        XCTAssertEqual(result?.altTitles, ["Refreshed alias"])
        XCTAssertEqual(result?.inLibrary, true)
        XCTAssertEqual(chapters.map(\.url), ["/refreshed-chapter"])
    }

    func testLibraryServiceGuardedRefreshRejectsOldConfigurationAndThenUsesCurrentToken() async throws {
        let f = try await fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await save(f)
        let old = try await execution(f)
        let original = try await f.store.persistSourceUpdate(
            manga: Manga(sourceId: Self.sourceID, url: "/refresh", title: "Original"),
            chapters: [.init(url: "/original-chapter", name: "Original")], expectedConfiguration: old
        )
        _ = try await f.preferences.saveConfiguration(snapshot: saved, userValues: values(adult: true))
        let id = try XCTUnwrap(original.manga.id)
        await expect(.staleConfiguration) {
            _ = try await LibraryService(store: f.store).refresh(
                mangaId: id, source: RefreshSource(id: Self.sourceID), expectedConfiguration: old
            )
        }
        let preserved = try await f.store.manga(id: id)
        let preservedChapters = try await f.store.chapters(mangaId: id)
        XCTAssertEqual(preserved?.title, "Original")
        XCTAssertEqual(preservedChapters.map(\.url), ["/original-chapter"])
        let current = try await execution(f)
        let refreshed = try await LibraryService(store: f.store).refresh(
            mangaId: id, source: RefreshSource(id: Self.sourceID), expectedConfiguration: current
        )
        XCTAssertEqual(refreshed?.title, "Refreshed")
        XCTAssertEqual(refreshed?.altTitles, ["Refreshed alias"])
    }
}

#endif
