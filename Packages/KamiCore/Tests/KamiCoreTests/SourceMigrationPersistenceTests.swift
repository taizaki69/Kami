import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

#if canImport(SQLite3)
@MainActor
final class SourceMigrationPersistenceTests: XCTestCase {
    private let archiveID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
    private struct Fixture {
        let directory: URL
        let path: String
        let store: LibraryStore
        let db: SQLiteDatabase
        let origin: Int64
        let chapter: Int64
        let selection: SourceDiscoveryStore
        let scope: SourceRequestScope
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path), db = try SQLiteDatabase(path: path)
        let origin = try db.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (7,'/original','Original',1)")
        let chapter = try db.insert("""
            INSERT INTO chapter(manga_id,url,name,number,read,bookmark,last_page_read)
            VALUES (?,'/original-c','Original chapter',1.25,1,1,17)
            """, [.int(origin)])
        try db.run("INSERT INTO history VALUES (?,?,123,456)", [.int(origin), .int(chapter)])
        let category = try db.insert("INSERT INTO category(name) VALUES ('Reading')")
        try db.run("INSERT INTO manga_category VALUES (?,?)", [.int(origin), .int(category)])
        return .init(directory: directory, path: path, store: store, db: db, origin: origin, chapter: chapter,
                     selection: try migrationSelection(), scope: .init())
    }

    private func candidate(_ f: Fixture, url: String = "/destination", sourceID: Int64 = MangaDexSource().id,
                           chapters: [SChapterCompat] = [.init(url: "/one", name: "Provider chapter", number: "1.25"),
                                                        .init(url: "/two", name: "Two", number: "2")]) async throws -> SourceMigrationCandidate {
        let source = MigrationTestSource(id: sourceID, chapterList: { chapters })
        let registration = SourceRegistrationSnapshot(source: source, revision: 1, origin: .native, scope: f.scope)
        return try await SourceMigrationCandidate.fetch(registration: registration,
            manga: .init(url: url, title: "Provider title"), selection: f.selection.snapshot())
    }

    private func preview(_ f: Fixture) async throws -> SourceMigrationPreview {
        return try await f.store.previewSourceMigration(origin: origin(f), destination: candidate(f), expectedConfiguration: nil)
    }

    private func origin(_ f: Fixture) async throws -> MangaReadingSnapshot {
        let saved = try await f.store.manga(id: f.origin)
        let manga = try XCTUnwrap(saved)
        let snapshot = try await f.store.readingSnapshot(sourceID: manga.sourceId, mangaURL: manga.url)
        return try XCTUnwrap(snapshot)
    }

    private func snapshot(_ f: Fixture) async throws -> LibraryBackupDocument {
        try await f.store.exportBackupSnapshot(exportID: archiveID, exportedAt: 0)
    }
    private func epoch(_ f: Fixture) throws -> [UInt8] { try XCTUnwrap(f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch")) }
    private func rejects(_ expected: SourceMigrationError, _ operation: () async throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? SourceMigrationError, expected, file: file, line: line) }
    }
    private func commit(_ f: Fixture, _ preview: SourceMigrationPreview, selected: Set<Int> = [0], categories: Bool = true) async throws -> SourceMigrationReport {
        try await f.store.commitSourceMigration(preview, selectedMatches: selected, copyCategories: categories)
    }

    private func download(_ f: Fixture, mangaID: Int64, chapterID: Int64, sourceID: Int64, state: Int = 2) throws {
        try f.db.run("""
            INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,
                state,revision,library_revision,publication_state,queue_order,created_at,updated_at)
            VALUES (?,?,?,?, 'saved-manga-digest','saved-chapter-digest',?,7,0,'none',0,123,456)
            """, [.text("fixture-\(chapterID)"), .int(chapterID), .int(mangaID), .int(sourceID), .int(state)])
    }
    private func downloadEvidence(_ f: Fixture) throws -> [UInt8] {
        try f.db.restoreDependencyBytes("SELECT * FROM download_job ORDER BY job_id", maximumRows: 10,
                                       maximumColumnBytes: 4096, maximumBytes: 65536)
    }

    func testPreviewIsReadOnlyAndAtomicMergePreservesOriginalDownloadsOffsetsAndHistory() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destinationID = try f.db.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,'/destination','Saved title',1)", [.int(MangaDexSource().id)])
        let c = try f.db.insert("INSERT INTO chapter(manga_id,url,name,number,last_page_read,bookmark) VALUES (?,'/one','Saved metadata',1.25,4,1)", [.int(destinationID)])
        let absent = try f.db.insert("INSERT INTO chapter(manga_id,url,name,number,read,last_page_read) VALUES (?,'/retained','Retained download',8,1,9)", [.int(destinationID)])
        try f.db.run("INSERT INTO history VALUES (?,?,88,99)", [.int(destinationID), .int(c)])
        try download(f, mangaID: f.origin, chapterID: f.chapter, sourceID: 7)
        try download(f, mangaID: destinationID, chapterID: absent, sourceID: MangaDexSource().id)
        let downloadBefore = try downloadEvidence(f), before = try await snapshot(f), oldEpoch = try epoch(f)
        let oldTarget = try await readingTargetForTest(store: f.store, mangaID: f.origin, chapterID: f.chapter)
        let plan = try await preview(f)
        XCTAssertTrue(plan.destinationExists); XCTAssertEqual(plan.matching.matches.count, 1)
        XCTAssertEqual(plan.categoryNames, ["Reading"])
        let unchanged = try await snapshot(f)
        XCTAssertEqual(unchanged, before); XCTAssertEqual(try epoch(f), oldEpoch)
        let report = try await commit(f, plan)
        XCTAssertEqual(report.destinationMangaID, destinationID); XCTAssertEqual(report.selectedChapters, 1)
        let saved = try await snapshot(f)
        XCTAssertEqual(saved.manga.first { $0.sourceID == 7 }, before.manga.first { $0.sourceID == 7 })
        let target = try XCTUnwrap(saved.manga.first { $0.sourceID == MangaDexSource().id })
        XCTAssertEqual(target.title, "Saved title"); XCTAssertEqual(target.categoryKeys.count, 1)
        let merged = try XCTUnwrap(target.chapters.first { $0.url == "/one" })
        XCTAssertEqual(merged.name, "Saved metadata"); XCTAssertTrue(merged.read); XCTAssertTrue(merged.bookmark)
        XCTAssertEqual(merged.lastPageRead, 4)
        XCTAssertEqual(target.chapters.first { $0.url == "/two" }?.lastPageRead, 0)
        XCTAssertEqual(target.chapters.first { $0.url == "/retained" }?.lastPageRead, 9)
        XCTAssertEqual(target.history, [.init(chapterURL: "/one", lastRead: 88, readDuration: 99)])
        XCTAssertEqual(try downloadEvidence(f), downloadBefore)
        XCTAssertTrue(target.knownChapters.allSatisfy { $0.detectedAt == nil })
        XCTAssertNotEqual(try epoch(f), oldEpoch)
        do { _ = try await f.store.validateReadingTarget(oldTarget); XCTFail("Old reader must expire") }
        catch { XCTAssertEqual(error as? ReadingStateError, .staleEpoch) }
        await rejects(.previewExpired) { _ = try await commit(f, plan) }
        let repeated = try await preview(f)
        _ = try await commit(f, repeated)
        let again = try await snapshot(f)
        XCTAssertEqual(again, saved, "Repeating a reviewed migration must not add history or duplicate chapters")
    }

    func testNewDestinationCopiesOnlySelectedFlagsAndOptionalCategoriesWithoutPageOrHistoryTransfer() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let plan = try await preview(f)
        let result = try await commit(f, plan, selected: [], categories: false)
        XCTAssertEqual(result.selectedChapters, 0)
        let saved = try await snapshot(f)
        let target = try XCTUnwrap(saved.manga.first { $0.sourceID == MangaDexSource().id })
        XCTAssertTrue(target.inLibrary); XCTAssertTrue(target.categoryKeys.isEmpty); XCTAssertTrue(target.history.isEmpty)
        XCTAssertTrue(target.chapters.allSatisfy { !$0.read && !$0.bookmark && $0.lastPageRead == 0 && $0.isCurrent })
        let next = try await preview(f)
        _ = try await commit(f, next)
        let merged = try await snapshot(f).manga.first { $0.sourceID == MangaDexSource().id }
        XCTAssertTrue(try XCTUnwrap(merged?.chapters.first { $0.url == "/one" }).read)
        XCTAssertEqual(merged?.chapters.first { $0.url == "/one" }?.lastPageRead, 0)
    }

    func testForeignPreviewAndInjectedMatchIDsAreRejectedWithoutWrites() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let plan = try await preview(f), before = try await snapshot(f)
        let second = try LibraryStore(path: f.path)
        await rejects(.foreignPreview) { _ = try await second.commitSourceMigration(plan, selectedMatches: [0], copyCategories: true) }
        await rejects(.invalidSelection) { _ = try await commit(f, plan, selected: [99]) }
        let after = try await snapshot(f); XCTAssertEqual(after, before)
    }

    func testExternalABAAndReadingChangesExpirePreview() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let plan = try await preview(f)
        try f.db.run("UPDATE chapter SET read=0 WHERE id=?", [.int(f.chapter)])
        try f.db.run("UPDATE chapter SET read=1 WHERE id=?", [.int(f.chapter)])
        let before = try await snapshot(f)
        await rejects(.previewExpired) { _ = try await commit(f, plan) }
        let after = try await snapshot(f); XCTAssertEqual(after, before)
    }

    func testRevokedSourceAndChangedSelectionCannotCommitPreparedCandidate() async throws {
        for selectionChange in [true, false] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let plan = try await preview(f), before = try await snapshot(f)
            if selectionChange { try f.selection.save(.none, expectedRevision: f.selection.state.revision) }
            else { f.scope.revoke() }
            await rejects(.sourceChanged) { _ = try await commit(f, plan) }
            let after = try await snapshot(f); XCTAssertEqual(after, before)
        }
    }

    func testSameExactIdentityMissingMembershipAndMissingExtensionConfigurationFailPreview() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("UPDATE manga SET source_id=? WHERE id=?", [.int(MangaDexSource().id), .int(f.origin)])
        let captured = try await origin(f)
        let same = try await candidate(f, url: "/original")
        await rejects(.sameManga) { _ = try await f.store.previewSourceMigration(origin: captured, destination: same, expectedConfiguration: nil) }
        let unknown = try await candidate(f, sourceID: Int64.min)
        do {
            _ = try await f.store.previewSourceMigration(origin: captured, destination: unknown, expectedConfiguration: nil)
            XCTFail("Downloaded source needs its execution configuration")
        } catch { XCTAssertEqual(error as? SourceUpdatePersistenceError, .configurationRequired) }
        try f.db.run("UPDATE manga SET in_library=0 WHERE id=?", [.int(f.origin)])
        try f.db.run("DELETE FROM manga_category WHERE manga_id=?", [.int(f.origin)])
        await rejects(.originUnavailable) { _ = try await preview(f) }
    }

    func testByteDistinctDestinationPathsDoNotMergeExistingMangaOrChapters() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let composed = "/caf\u{e9}", decomposed = "/cafe\u{301}"
        try f.db.run("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,?,'Existing',1)", [.int(MangaDexSource().id), .text(composed)])
        let destination = try await candidate(f, url: decomposed, chapters: [
            .init(url: composed, name: "A", number: "1.25"), .init(url: decomposed, name: "B", number: "2")])
        let captured = try await origin(f)
        let plan = try await f.store.previewSourceMigration(origin: captured, destination: destination, expectedConfiguration: nil)
        XCTAssertFalse(plan.destinationExists)
        _ = try await commit(f, plan)
        let saved = try await snapshot(f)
        let targets = saved.manga.filter { $0.sourceID == MangaDexSource().id }
        XCTAssertEqual(targets.count, 2)
        let target = try XCTUnwrap(targets.first { Data($0.url.utf8) == Data(decomposed.utf8) })
        XCTAssertEqual(Set(target.chapters.map { Data($0.url.utf8) }).count, 2)
        XCTAssertTrue(try XCTUnwrap(target.chapters.first { Data($0.url.utf8) == Data(composed.utf8) }).read)
        XCTAssertFalse(try XCTUnwrap(target.chapters.first { Data($0.url.utf8) == Data(decomposed.utf8) }).read)
    }

    func testOriginIdentityCannotBeReboundWhileDestinationIsBeingFetched() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let captured = try await origin(f), destination = try await candidate(f)
        try f.db.run("UPDATE manga SET url='/replacement' WHERE id=?", [.int(f.origin)])
        await rejects(.originUnavailable) {
            _ = try await f.store.previewSourceMigration(origin: captured, destination: destination, expectedConfiguration: nil)
        }
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int("n"), 1)
    }

    func testConfiguredDestinationRetainsDeploymentAndRejectsChangedExecutionSnapshot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        // Descriptive trust/configuration fixture only; no APK file is created,
        // admitted or executed. The candidate provider is MigrationTestSource.
        let schema = try XCTUnwrap(SourceContentBindingPersistence.schema), identity = schema.identity
        let installed = InstalledExtensionTrust(packageName: identity.packageName, versionName: identity.versionName,
            versionCode: identity.versionCode, apkPath: f.directory.appendingPathComponent("absent.apk").path,
            apkSHA256: identity.apkSHA256, signatureScheme: .v2, currentSigners: [identity.signerFingerprint],
            signerHistory: [identity.signerFingerprint], trustSource: .user(fingerprint: identity.signerFingerprint),
            sourceIDs: identity.sourceIDs, repositoryURL: nil, installedAt: 123, enabled: true)
        let signers = String(decoding: try JSONEncoder().encode(installed.currentSigners), as: UTF8.self)
        let sourceIDs = String(decoding: try JSONEncoder().encode(installed.sourceIDs.sorted()), as: UTF8.self)
        try f.db.run("""
            INSERT INTO installed_extension(package_name,version_name,version_code,apk_path,apk_sha256,
                signature_scheme,current_signers,signer_history,trust_source,source_ids,installed_at,enabled)
            VALUES (?,?,?,?,?,'v2',?,?,?,?,123,1)
            """, [.text(installed.packageName), .text(installed.versionName), .int(installed.versionCode),
                  .text(installed.apkPath), .text(installed.apkSHA256), .text(signers), .text(signers),
                  .text(installed.trustSource.persistedValue), .text(sourceIDs)])
        let website = "https://fixture.invalid/reader"
        let values = try StoredExtensionPreferenceValues([.baseURL: .string(website), .adult: .boolean(false)]).encoded()
        try f.db.run("""
            INSERT INTO installed_extension_preferences(package_name,identity_fingerprint,schema_revision,revision,user_values)
            VALUES (?,?,?,7,?)
            """, [.text(installed.packageName), .text(try ExtensionPreferenceBinding.fingerprint(installed)),
                  .int(schema.revision), .text(values)])
        try f.db.run("INSERT INTO source_content_binding VALUES (?,'deployment',?,1)", [.int(SourceContentBindingPersistence.sourceID), .text(website)])
        let configuration = try await f.store.extensionConfigurationSnapshot(installed: installed, schema: schema)
        let execution = ExtensionExecutionConfiguration(installed: installed, runtimePreferences: nil, snapshot: configuration)
        let captured = try await origin(f), destination = try await candidate(f, sourceID: SourceContentBindingPersistence.sourceID)
        let plan = try await f.store.previewSourceMigration(origin: captured, destination: destination, expectedConfiguration: execution)
        _ = try await commit(f, plan)
        XCTAssertEqual(try SourceContentBindingPersistence.read(f.db), configuration.contentBinding)
        XCTAssertEqual(try f.db.query("SELECT user_values FROM installed_extension_preferences").first?.string("user_values"), values)
        let current = try await origin(f)
        let second = try await f.store.previewSourceMigration(origin: current, destination: destination, expectedConfiguration: execution)
        try f.db.run("UPDATE installed_extension_preferences SET revision=8")
        await rejects(.previewExpired) { _ = try await commit(f, second) }
        do {
            _ = try await f.store.previewSourceMigration(origin: current, destination: destination, expectedConfiguration: execution)
            XCTFail("Old execution configuration must be rejected")
        } catch { XCTAssertEqual(error as? ExtensionPreferencesError, .staleConfiguration) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.apkPath))
    }

    func testPartialStorageFailureRollsBackDestinationCategoriesAndEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.execute("CREATE TRIGGER fail_migration BEFORE INSERT ON chapter WHEN NEW.url='/two' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let plan = try await preview(f), before = try await snapshot(f), oldEpoch = try epoch(f)
        await rejects(.storageUnavailable) { _ = try await commit(f, plan) }
        let after = try await snapshot(f); XCTAssertEqual(after, before); XCTAssertEqual(try epoch(f), oldEpoch)
    }

    func testActiveDurableDownloadsAndUpdatesRefuseCommit() async throws {
        for downloadActive in [true, false] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            if downloadActive { try download(f, mangaID: f.origin, chapterID: f.chapter, sourceID: 7, state: 1) }
            else { _ = try await f.store.beginLibraryUpdateScan() }
            let plan = try await preview(f), before = try await snapshot(f), oldEpoch = try epoch(f)
            await rejects(.activeWork) { _ = try await commit(f, plan) }
            let after = try await snapshot(f); XCTAssertEqual(after, before); XCTAssertEqual(try epoch(f), oldEpoch)
        }
    }

    func testManualUnknownAndDuplicatePairsCopyExactFlagsWithoutMovingOriginalHistoryPagesOrDownloads() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        for (url, number, read, bookmark) in [("/dup-a", 2, true, false), ("/dup-b", 2, false, true), ("/unknown", -1, false, true)] {
            try f.db.run("INSERT INTO chapter(manga_id,url,name,number,read,bookmark,last_page_read) VALUES (?,?,?, ?,?,?,9)",
                         [.int(f.origin), .text(url), .text(url), .int(number), .bool(read), .bool(bookmark)])
        }
        try download(f, mangaID: f.origin, chapterID: f.chapter, sourceID: 7)
        let downloadBefore = try downloadEvidence(f), before = try await snapshot(f)
        let composed = "/caf\u{e9}", decomposed = "/cafe\u{301}"
        let destination = try await candidate(f, chapters: [
            .init(url: "/one", name: "One", number: "1.25"),
            .init(url: composed, name: "Edition A", number: "2"),
            .init(url: decomposed, name: "Edition B", number: "2"),
            .init(url: "/special", name: "Special", chapterNumber: -1)])
        let plan = try await f.store.previewSourceMigration(origin: origin(f), destination: destination, expectedConfiguration: nil)
        var draft = plan.makeDraft()
        XCTAssertEqual(draft.matchedCount, 1)
        for (originalURL, destinationURL) in [("/dup-a", decomposed), ("/dup-b", composed), ("/unknown", "/special")] {
            let left = try XCTUnwrap(plan.original.chapters.firstIndex { Data($0.url.utf8) == Data(originalURL.utf8) })
            let right = try XCTUnwrap(plan.destination.manga.chapters.firstIndex { Data($0.url.utf8) == Data(destinationURL.utf8) })
            try draft.assign(destination: right, to: left)
        }
        XCTAssertEqual(draft.manualCount, 3); XCTAssertEqual(draft.unmatchedOriginalCount, 0)
        let coordinator = LibraryOperationCoordinator(), generation = coordinator.state.presentation
        let worker = try coordinator.startSourceMigration(store: f.store, preview: plan, selection: draft.selection,
            copyCategories: true, expected: generation)
        let completion = try await worker.value
        XCTAssertTrue(completion.presentationPublished); XCTAssertNotEqual(coordinator.state.presentation, generation)
        XCTAssertEqual(completion.report.selectedChapters, 4)
        let saved = try await snapshot(f)
        XCTAssertEqual(saved.manga.first { $0.sourceID == 7 }, before.manga.first { $0.sourceID == 7 })
        XCTAssertEqual(try downloadEvidence(f), downloadBefore)
        let target = try XCTUnwrap(saved.manga.first { $0.sourceID == MangaDexSource().id })
        let flags = Dictionary(uniqueKeysWithValues: target.chapters.map { (Data($0.url.utf8), $0) })
        XCTAssertTrue(try XCTUnwrap(flags[Data(decomposed.utf8)]).read)
        XCTAssertFalse(try XCTUnwrap(flags[Data(decomposed.utf8)]).bookmark)
        XCTAssertFalse(try XCTUnwrap(flags[Data(composed.utf8)]).read)
        XCTAssertTrue(try XCTUnwrap(flags[Data(composed.utf8)]).bookmark)
        XCTAssertTrue(try XCTUnwrap(flags[Data("/special".utf8)]).bookmark)
        XCTAssertTrue(target.history.isEmpty); XCTAssertTrue(target.chapters.allSatisfy { $0.lastPageRead == 0 })
        XCTAssertEqual(target.categoryKeys.count, 1)
    }

    func testMalformedManualSelectionsCannotInjectOrDuplicatePreviewChapterIdentities() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("INSERT INTO chapter(manga_id,url,name,number) VALUES (?,'/extra','Extra',-1)", [.int(f.origin)])
        let plan = try await preview(f), before = try await snapshot(f), oldEpoch = try epoch(f)
        let malformed: [[SourceMigrationPair]] = [
            [.init(originalIndex: -1, destinationIndex: 0)], [.init(originalIndex: 0, destinationIndex: Int.max)],
            [.init(originalIndex: Int.max, destinationIndex: 0)], [.init(originalIndex: 0, destinationIndex: -1)],
            [.init(originalIndex: 0, destinationIndex: 0), .init(originalIndex: 0, destinationIndex: 1)],
            [.init(originalIndex: 0, destinationIndex: 0), .init(originalIndex: 1, destinationIndex: 0)]
        ]
        for pairs in malformed {
            let selection = SourceMigrationSelection(previewID: plan.id, pairs: pairs)
            await rejects(.invalidSelection) {
                _ = try await f.store.commitSourceMigration(plan, selection: selection, copyCategories: true)
            }
        }
        let after = try await snapshot(f); XCTAssertEqual(after, before); XCTAssertEqual(try epoch(f), oldEpoch)
    }

    func testSelectionCannotRebaseOntoAnotherPreviewAndRejectsBeforeExclusiveReservation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await preview(f), second = try await preview(f)
        var draft = first.makeDraft()
        let originalIndex = try XCTUnwrap(first.matching.matches.first?.id)
        try draft.assign(destination: 1, to: originalIndex)
        let selection = draft.selection, coordinator = LibraryOperationCoordinator()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertThrowsError(try coordinator.startSourceMigration(store: f.store, preview: second, selection: selection,
            copyCategories: true, expected: coordinator.state.presentation)) {
            XCTAssertEqual($0 as? SourceMigrationError, .invalidSelection)
        }
        XCTAssertFalse(coordinator.state.isExclusive); XCTAssertEqual(coordinator.state.activeOperations, 0)
        await rejects(.invalidSelection) {
            _ = try await f.store.commitSourceMigration(second, selection: selection, copyCategories: false)
        }
        try f.db.run("UPDATE chapter SET read=0 WHERE id=?", [.int(f.chapter)])
        try f.db.run("UPDATE chapter SET read=1 WHERE id=?", [.int(f.chapter)])
        await rejects(.previewExpired) {
            _ = try await f.store.commitSourceMigration(first, selection: selection, copyCategories: true)
        }
    }

    func testCancellingQueuedManualSelectionKeepsLibraryAndEpochUnchanged() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let plan = try await preview(f), before = try await snapshot(f), oldEpoch = try epoch(f)
        var draft = plan.makeDraft()
        try draft.assign(destination: 1, to: try XCTUnwrap(plan.matching.matches.first?.id))
        let coordinator = LibraryOperationCoordinator(), generation = coordinator.state.presentation
        let worker = try coordinator.startSourceMigration(store: f.store, preview: plan, selection: draft.selection,
            copyCategories: true, expected: generation)
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(coordinator.state.isExclusive); XCTAssertEqual(coordinator.state.presentation, generation)
        let after = try await snapshot(f); XCTAssertEqual(after, before); XCTAssertEqual(try epoch(f), oldEpoch)
    }

    func testExclusiveCoordinatorRejectsReadersCancelsBeforeStartAndPublishesDespiteLateCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let plan = try await preview(f), oldEpoch = try epoch(f), coordinator = LibraryOperationCoordinator()
        let generation = coordinator.state.presentation
        let reader = try coordinator.open(expected: generation)
        XCTAssertThrowsError(try coordinator.startSourceMigration(store: f.store, preview: plan, selectedMatches: [0], copyCategories: true, expected: generation))
        reader.close()
        let cancelled = try coordinator.startSourceMigration(store: f.store, preview: plan, selectedMatches: [0], copyCategories: true, expected: generation)
        cancelled.cancel()
        XCTAssertTrue(coordinator.state.isExclusive)
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(coordinator.state.presentation, generation); XCTAssertEqual(try epoch(f), oldEpoch)
        var operation: Task<SourceMigrationCompletion, Error>?
        coordinator.onStateChanged = { state in
            if state.isExclusive && state.presentation != generation { operation?.cancel() }
        }
        operation = try coordinator.startSourceMigration(store: f.store, preview: plan, selectedMatches: [0], copyCategories: true, expected: generation)
        let completion = try await XCTUnwrap(operation).value
        XCTAssertTrue(completion.presentationPublished); XCTAssertTrue(try XCTUnwrap(operation).isCancelled)
        XCTAssertFalse(coordinator.state.isExclusive); XCTAssertNotEqual(coordinator.state.presentation, generation)
        XCTAssertNotEqual(try epoch(f), oldEpoch)
        coordinator.onStateChanged = nil
    }
}
#endif
