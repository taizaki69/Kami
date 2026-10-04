import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)
final class LibraryBackupSnapshotTests: XCTestCase {
    private let exportID = UUID(uuidString: "EC627F64-D7C6-45A4-BDE9-842B0BA8638B")!

    private struct Fixture {
        let directory: URL
        let db: SQLiteDatabase
        let store: LibraryStore
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        return Fixture(directory: directory, db: try SQLiteDatabase(path: path), store: store)
    }

    @discardableResult
    private func manga(_ f: Fixture, source: Int64 = 9_007_199_254_740_993,
                       url: String = "/m", inLibrary: Bool = true) throws -> Int64 {
        try f.db.insert("""
            INSERT INTO manga(source_id,url,title,alt_titles,thumbnail_url,author,artist,description,
                genres,status,in_library,date_added,date_updated,last_fetched,update_strategy,initialized)
            VALUES (?,?, 'Saved title', '["Alias"]', 'https://fixture.invalid/cover', 'Author', 'Artist',
                'Description', '["Adventure"]',2,?,123,456,789,'ONLY_FETCH_ONCE',0)
            """, [.int(source), .text(url), .bool(inLibrary)])
    }

    @discardableResult
    private func chapter(_ f: Fixture, mangaID: Int64, url: String = "/c", current: Bool = true) throws -> Int64 {
        try f.db.insert("""
            INSERT INTO chapter(manga_id,url,name,source_order,scanlator,number,date_upload,date_fetch,
                read,bookmark,last_page_read,is_current)
            VALUES (?,?,'Saved chapter',4294967305,'Team',2.25,1700000000123,1700000000456,1,1,4294967311,?)
            """, [.int(mangaID), .text(url), .bool(current)])
    }

    /// Saved descriptive provenance only: this fixture neither loads nor admits
    /// an APK. The missing path proves snapshot export needs no execution.
    private func configuredFoolSlide(_ f: Fixture, baseURL: String) throws -> InstalledExtensionTrust {
        let schema = try XCTUnwrap(InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: "eu.kanade.tachiyomi.extension.all.foolslidecustomizable",
            versionName: "1.6.6", versionCode: 6
        ))
        _ = try schema.validateUserValues([.baseURL: .string(baseURL), .adult: .boolean(false)])
        let identity = schema.identity
        let installed = InstalledExtensionTrust(
            packageName: identity.packageName, versionName: identity.versionName,
            versionCode: identity.versionCode, apkPath: f.directory.appendingPathComponent("missing.apk").path,
            apkSHA256: identity.apkSHA256, signatureScheme: .v2,
            currentSigners: [identity.signerFingerprint], signerHistory: [identity.signerFingerprint],
            trustSource: .user(fingerprint: identity.signerFingerprint), sourceIDs: identity.sourceIDs,
            repositoryURL: nil, installedAt: 123, enabled: false
        )
        let signers = String(decoding: try JSONEncoder().encode(installed.currentSigners), as: UTF8.self)
        let sourceIDs = String(decoding: try JSONEncoder().encode(installed.sourceIDs.sorted()), as: UTF8.self)
        try f.db.run("""
            INSERT INTO installed_extension(package_name,version_name,version_code,apk_path,
                apk_sha256,signature_scheme,current_signers,signer_history,trust_source,source_ids,installed_at,enabled)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
            """, [.text(installed.packageName), .text(installed.versionName), .int(installed.versionCode),
                  .text(installed.apkPath), .text(installed.apkSHA256), .text(installed.signatureScheme.rawValue),
                  .text(signers), .text(signers), .text(installed.trustSource.persistedValue),
                  .text(sourceIDs), .int(installed.installedAt)])
        let values = try StoredExtensionPreferenceValues([.baseURL: .string(baseURL), .adult: .boolean(false)]).encoded()
        try f.db.run("""
            INSERT INTO installed_extension_preferences(package_name,identity_fingerprint,schema_revision,revision,user_values)
            VALUES (?,?,?,1,?)
            """, [.text(installed.packageName), .text(try ExtensionPreferenceBinding.fingerprint(installed)),
                  .int(schema.revision), .text(values)])
        return installed
    }

    func testSnapshotPreservesHiddenChaptersAllHistoryNonlibraryRowsAndDiscoveryState() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try manga(f)
        _ = try manga(f, source: Int64.min, url: "/not-in-library", inLibrary: false)
        let categoryID = try f.db.insert("INSERT INTO category(name,sort_order,flags) VALUES ('Reading',7,4294967301)")
        try f.db.run("INSERT INTO category(name,sort_order,flags) VALUES ('Empty',9,-1)")
        try f.db.run("INSERT INTO manga_category(manga_id,category_id) VALUES (?,?)", [.int(id), .int(categoryID)])
        try f.db.execute("BEGIN")
        for index in 0..<205 {
            let cid = try chapter(f, mangaID: id, url: "/c/\(index)", current: index != 0)
            try f.db.run("INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,?,?)",
                         [.int(id), .int(cid), .int(1_780_000_000 + index), .int(Int64(5_000_000_001))])
        }
        try f.db.execute("COMMIT")
        try f.db.run("INSERT INTO chapter_discovery_baseline(manga_id,established_at) VALUES (?,0)", [.int(id)])
        try f.db.run("INSERT INTO known_chapter(manga_id,url,first_seen,detected_at) VALUES (?,'/known-without-row',111,222)", [.int(id)])
        try f.db.run("INSERT INTO known_chapter(manga_id,url,first_seen,detected_at) VALUES (?,'/c/0',0,NULL)", [.int(id)])

        let displayedHistory = try await f.store.history()
        let displayedChapters = try await f.store.chapters(mangaId: id)
        XCTAssertEqual(displayedHistory.count, 200)
        XCTAssertEqual(displayedChapters.count, 204)

        let doc = try await f.store.exportBackupSnapshot(exportID: exportID, exportedAt: 1_790_000_000)
        XCTAssertEqual(doc.manga.count, 2)
        XCTAssertEqual(doc.sources.map(\.sourceID), [Int64.min, 9_007_199_254_740_993])
        let m = try XCTUnwrap(doc.manga.first { $0.url == "/m" })
        XCTAssertEqual(m.title, "Saved title")
        XCTAssertEqual(m.altTitles, ["Alias"])
        XCTAssertEqual(m.thumbnailURL, "https://fixture.invalid/cover")
        XCTAssertEqual(m.author, "Author")
        XCTAssertEqual(m.artist, "Artist")
        XCTAssertEqual(m.descriptionText, "Description")
        XCTAssertEqual(m.genres, ["Adventure"])
        XCTAssertEqual(m.status, .completed)
        XCTAssertEqual(m.dateAdded, 123)
        XCTAssertEqual(m.dateUpdated, 456)
        XCTAssertEqual(m.lastFetched, 789)
        XCTAssertEqual(m.updateStrategy, .onlyFetchOnce)
        XCTAssertFalse(m.initialized)
        XCTAssertEqual(m.chapters.count, 205)
        XCTAssertEqual(m.history.count, 205)
        XCTAssertTrue(m.history.allSatisfy { $0.readDuration == 5_000_000_001 })
        let hidden = try XCTUnwrap(m.chapters.first { $0.url == "/c/0" })
        XCTAssertFalse(hidden.isCurrent)
        XCTAssertTrue(hidden.read)
        XCTAssertTrue(hidden.bookmark)
        XCTAssertEqual(hidden.sourceOrder, 4_294_967_305)
        XCTAssertEqual(hidden.lastPageRead, 4_294_967_311)
        XCTAssertEqual(hidden.dateFetch, 1_700_000_000_456)
        XCTAssertEqual(hidden.dateUpload, 1_700_000_000_123)
        XCTAssertEqual(hidden.number, 2.25)
        XCTAssertEqual(m.discoveryBaseline?.establishedAt, 0)
        XCTAssertEqual(m.knownChapters.first { $0.url == "/known-without-row" }?.detectedAt, 222)
        XCTAssertNil(m.knownChapters.first { $0.url == "/c/0" }?.detectedAt)
        XCTAssertEqual(doc.categories.map(\.flags), [4_294_967_301, -1])
        XCTAssertEqual(m.categoryKeys, [doc.categories[0].key])
        XCTAssertFalse(try XCTUnwrap(doc.manga.first { $0.url == "/not-in-library" }).inLibrary)

        let bytes = try LibraryBackupCodec().encode(doc)
        let roundTrip = try LibraryBackupCodec().decode(bytes)
        XCTAssertEqual(roundTrip.manga.first { $0.url == "/m" }?.history.count, 205)
        let again = try await f.store.exportBackupSnapshot(exportID: exportID, exportedAt: 1_790_000_000)
        XCTAssertEqual(try LibraryBackupCodec().encode(again), bytes)
    }

    func testSnapshotDoesNotExportAuthorityOrMutateRunningWork() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try manga(f)
        try f.db.run("INSERT INTO extension_repo(url,name,trusted,signing_key) VALUES ('https://secret.invalid','Private repo',1,'SECRET-SIGNING-KEY')")
        try f.db.run("INSERT INTO source_preference(source_id,key,value) VALUES (1,'token','SECRET-COOKIE')")
        let scan = UUID().uuidString
        try f.db.run("INSERT INTO library_update_scan(scan_id,status,started_at,total) VALUES (?,'running',123,0)", [.text(scan)])
        let doc = try await f.store.exportBackupSnapshot(exportID: exportID, exportedAt: 456)
        let text = String(decoding: try LibraryBackupCodec().encode(doc), as: UTF8.self)
        for secret in ["SECRET-SIGNING-KEY", "SECRET-COOKIE", "secret.invalid", scan, f.directory.path] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertEqual(try f.db.query("SELECT status FROM library_update_scan").first?.string("status"), "running")
        XCTAssertEqual(try f.db.query("SELECT trusted FROM extension_repo").first?.int("trusted"), 1)
    }

    func testCountLimitsIncludeHiddenAndNonlibraryRowsBeforeMaterialization() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try manga(f)
        _ = try manga(f, url: "/nonlibrary", inLibrary: false)
        _ = try chapter(f, mangaID: id, current: false)
        for policy in [try LibraryBackupPolicy(maximumManga: 1), try LibraryBackupPolicy(maximumChapters: 0),
                       try LibraryBackupPolicy(maximumChaptersPerManga: 0), try LibraryBackupPolicy(maximumSources: 0)] {
            do {
                _ = try await f.store.exportBackupSnapshot(exportedAt: 0, policy: policy)
                XCTFail("exceeded snapshot limit")
            } catch {
                XCTAssertEqual(error as? LibraryBackupSnapshotError, .exportLimitExceeded)
            }
        }
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int("n"), 2)
    }

    func testCorruptStoredScalarsCannotSilentlyBecomeValidDefaults() async throws {
        let corruptions = [
            "UPDATE manga SET url=CAST(X'2F6D00FF' AS TEXT)",
            "UPDATE manga SET title=CAST(X'C328' AS TEXT)",
            "UPDATE manga SET status=99", "UPDATE manga SET in_library=2",
            "UPDATE manga SET initialized=2", "UPDATE manga SET date_added='bad'",
            "UPDATE manga SET genres='broken-json'", "UPDATE manga SET alt_titles='[null]'",
            "UPDATE manga SET update_strategy='NEW_UNKNOWN_STRATEGY'",
        ]
        for sql in corruptions {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let id = try manga(f)
            try f.db.execute(sql)
            do {
                _ = try await f.store.exportBackupSnapshot(exportedAt: 0)
                XCTFail("corrupt row accepted: \(sql)")
            } catch {
                XCTAssertTrue(error is LibraryBackupSnapshotError || error is LibraryBackupError)
            }
            // A failed snapshot changes no data and releases the store's own
            // transaction, proven by a subsequent transaction on that actor.
            XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int("n"), 1)
            try await f.store.setLibrary(false, mangaId: id)
            XCTAssertEqual(try f.db.query("SELECT in_library FROM manga").first?.int("in_library"), 0)
        }
    }

    func testOversizedStoredTextAndArrayCountsFailInsteadOfAllocatingUnboundedModels() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try manga(f)
        try f.db.run("UPDATE manga SET title='Four'")
        do {
            _ = try await f.store.exportBackupSnapshot(exportedAt: 0, policy: try .init(maximumMetadataBytes: 3))
            XCTFail("oversized stored title accepted")
        } catch { XCTAssertEqual(error as? LibraryBackupSnapshotError, .invalidStoredData) }
        try f.db.run("UPDATE manga SET title='',alt_titles='[\"\",\"\",\"\"]'")
        do {
            _ = try await f.store.exportBackupSnapshot(exportedAt: 0, policy: try .init(maximumAlternateTitles: 2))
            XCTFail("oversized string array accepted")
        } catch { XCTAssertEqual(error as? LibraryBackupError, .limitExceeded(.jsonArrayElements)) }
    }

    func testCrossMangaHistoryAndNonlibraryMembershipAreRejected() async throws {
        for brokenHistory in [true, false] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let first = try manga(f)
            let second = try manga(f, url: "/second", inLibrary: false)
            if brokenHistory {
                let cid = try chapter(f, mangaID: first)
                try f.db.run("INSERT INTO history(manga_id,chapter_id) VALUES (?,?)", [.int(second), .int(cid)])
            } else {
                let cat = try f.db.insert("INSERT INTO category(name) VALUES ('Reading')")
                try f.db.run("INSERT INTO manga_category(manga_id,category_id) VALUES (?,?)", [.int(second), .int(cat)])
            }
            do {
                _ = try await f.store.exportBackupSnapshot(exportedAt: 0)
                XCTFail("invalid relationship accepted")
            } catch { XCTAssertEqual(error as? LibraryBackupSnapshotError, .invalidStoredData) }
        }
    }

    func testExactUnicodeURLSpellingsAreBothPreserved() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let composed = "/caf\u{00e9}", decomposed = "/cafe\u{0301}"
        _ = try manga(f, url: composed)
        _ = try manga(f, url: decomposed)
        let doc = try await f.store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(doc.manga.count, 2)
        XCTAssertEqual(Set(doc.manga.map { Data($0.url.utf8) }), [Data(composed.utf8), Data(decomposed.utf8)])
        let decoded = try LibraryBackupCodec().decode(LibraryBackupCodec().encode(doc))
        XCTAssertEqual(Set(decoded.manga.map { Data($0.url.utf8) }), [Data(composed.utf8), Data(decomposed.utf8)])
    }

    func testUnconfiguredFoolSlideIsExplicitlyUnresolvedWithoutCreatingSettings() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try manga(f, source: 6_351_052_922_295_965_587)
        let doc = try await f.store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(doc.sources.first?.contentBinding.kind, .unresolved)
        XCTAssertNil(doc.sources.first?.contentBinding.deploymentURL)
        XCTAssertTrue(try f.db.query("SELECT * FROM installed_extension_preferences").isEmpty)
        XCTAssertTrue(try f.db.query("SELECT * FROM installed_extension").isEmpty)
    }

    func testConfiguredFoolSlideNamespaceSurvivesDisabledExtensionAndMissingAPK() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let baseURL = "https://Archive.Example/reader"
        let installed = try configuredFoolSlide(f, baseURL: baseURL)
        _ = try manga(f, source: 6_351_052_922_295_965_587)
        let storedValues = try f.db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values")
        let doc = try await f.store.exportBackupSnapshot(exportedAt: 0)
        XCTAssertEqual(doc.sources.first?.contentBinding.kind, .deployment)
        XCTAssertEqual(doc.sources.first?.contentBinding.deploymentURL.map { Data($0.utf8) }, Data(baseURL.utf8))
        let bytes = try LibraryBackupCodec().encode(doc)
        XCTAssertEqual(try LibraryBackupCodec().decode(bytes), doc)
        let text = String(decoding: bytes, as: UTF8.self)
        for excluded in [installed.apkPath, installed.apkSHA256, installed.currentSigners[0], "user_values"] {
            XCTAssertFalse(text.contains(excluded))
        }
        let after = try await f.store.installedExtensionTrust(packageName: installed.packageName)
        XCTAssertEqual(after, installed)
        XCTAssertEqual(try f.db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values"), storedValues)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.apkPath))
    }

    func testCorruptFoolSlideProvenanceIsUnresolvedAndNeverRewritten() async throws {
        let corruptions = [
            "UPDATE installed_extension SET apk_sha256='wrong'",
            "UPDATE installed_extension SET current_signers='[]'",
            "UPDATE installed_extension SET source_ids='[1]'",
            "UPDATE installed_extension_preferences SET identity_fingerprint=replace(hex(zeroblob(32)),'0','f')",
            "UPDATE installed_extension_preferences SET schema_revision=99",
            "UPDATE installed_extension_preferences SET user_values=CAST(X'C328' AS TEXT)",
            "UPDATE installed_extension_preferences SET user_values=user_values || char(0)",
            "UPDATE installed_extension SET enabled=2",
        ]
        for sql in corruptions {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try configuredFoolSlide(f, baseURL: "https://fixture.example/reader")
            _ = try manga(f, source: 6_351_052_922_295_965_587)
            try f.db.execute(sql)
            let before = try provenanceBytes(f)
            let doc = try await f.store.exportBackupSnapshot(exportedAt: 0)
            XCTAssertEqual(doc.sources.first?.contentBinding.kind, .unresolved, sql)
            XCTAssertNil(doc.sources.first?.contentBinding.deploymentURL, sql)
            XCTAssertEqual(try provenanceBytes(f), before)
        }
    }

    private func provenanceBytes(_ f: Fixture) throws -> [String] {
        let fields = [
            "installed_extension": ["package_name", "version_name", "version_code", "apk_path", "apk_sha256",
                                    "signature_scheme", "current_signers", "signer_history", "trust_source",
                                    "source_ids", "installed_at", "enabled", "repo_url"],
            "installed_extension_preferences": ["package_name", "identity_fingerprint", "schema_revision", "revision", "user_values"],
        ]
        return try fields.keys.sorted().flatMap { table in
            try fields[table]!.map { column in
                try XCTUnwrap(f.db.query("SELECT typeof(\(column)) || ':' || hex(CAST(\(column) AS BLOB)) AS value FROM \(table)").first?.string("value"))
            }
        }
    }

    func testFoolSlideNumericAffinityCannotMaterializeUnboundedTextOrBlobs() async throws {
        for (table, column) in [
            ("installed_extension", "version_code"), ("installed_extension", "installed_at"),
            ("installed_extension", "enabled"), ("installed_extension_preferences", "schema_revision"),
            ("installed_extension_preferences", "revision"),
        ] {
            for expression in ["CAST(zeroblob(20000) AS TEXT)", "zeroblob(20000)"] {
                let f = try fixture()
                defer { try? FileManager.default.removeItem(at: f.directory) }
                _ = try configuredFoolSlide(f, baseURL: "https://fixture.example/reader")
                _ = try manga(f, source: 6_351_052_922_295_965_587)
                try f.db.execute("UPDATE \(table) SET \(column)=\(expression)")
                XCTAssertFalse(try LibraryBackupSnapshotReader.hasBoundedFoolSlideConfiguration(f.db))
                let doc = try await f.store.exportBackupSnapshot(exportedAt: 0)
                XCTAssertEqual(doc.sources.first?.contentBinding.kind, .unresolved)
                XCTAssertNil(doc.sources.first?.contentBinding.deploymentURL)
                XCTAssertEqual(try f.db.query("SELECT length(CAST(\(column) AS BLOB)) AS n FROM \(table)").first?.int("n"), 20000)
            }
        }
    }

    func testCancelledSnapshotDoesNotPublishDocumentOrMutateData() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = try manga(f)
        let store = f.store
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.exportBackupSnapshot(exportedAt: 0)
        }
        do { _ = try await task.value; XCTFail("cancelled snapshot completed") }
        catch is CancellationError { }
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int("n"), 1)
        try await f.store.setLibrary(false, mangaId: id)
        XCTAssertEqual(try f.db.query("SELECT in_library FROM manga").first?.int("in_library"), 0)
    }
}
#endif
