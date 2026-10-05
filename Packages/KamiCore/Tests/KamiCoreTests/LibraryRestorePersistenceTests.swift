import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)
final class LibraryRestorePersistenceTests: XCTestCase {
    private typealias Doc = LibraryBackupDocument
    private let archiveID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    private struct Fixture {
        let directory: URL
        let db: SQLiteDatabase
        let store: LibraryStore
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Restore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path)
        return .init(directory: directory, db: try SQLiteDatabase(path: path), store: store)
    }
    private func bytes(_ manga: [Doc.Manga] = [], categories: [Doc.Category] = [], sources: [Doc.Source]? = nil) throws -> Data {
        let declared = sources ?? Set(manga.map(\.sourceID)).sorted().map { Doc.Source(sourceID: $0, name: "Source \($0)") }
        return try LibraryBackupCodec().encode(.init(exportID: archiveID, exportedAt: 123,
                                                     sources: declared, categories: categories, manga: manga))
    }
    private func seed(_ f: Fixture) throws -> (Int64, Int64) {
        let manga = try f.db.insert("INSERT INTO manga(source_id,url,title,in_library) VALUES (7,'/m','Saved',1)")
        let chapter = try f.db.insert("INSERT INTO chapter(manga_id,url,name,number,last_page_read,bookmark) VALUES (?,'/c','Saved chapter',2.5,8,1)", [.int(manga)])
        return (manga, chapter)
    }
    private func snapshot(_ f: Fixture) async throws -> Data {
        try LibraryBackupCodec().encode(await f.store.exportBackupSnapshot(exportID: archiveID, exportedAt: 0))
    }
    private func assertSnapshot(_ f: Fixture, equals expected: Data, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await snapshot(f)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
    private func epoch(_ f: Fixture) throws -> [UInt8] {
        try XCTUnwrap(f.db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch"))
    }
    private func rejects(_ expected: LibraryRestoreError, _ action: () async throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? LibraryRestoreError, expected, file: file, line: line) }
    }

    @MainActor
    func testRestoreOperationReservesBeforeSchedulingAndRefusesReadersAndPendingWork() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new", title: "New")]))
        let shared = LibraryOperationCoordinator(), oldEpoch = try epoch(f)
        let generation = shared.state.presentation
        let reader = try shared.open(expected: generation)
        XCTAssertThrowsError(try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)) {
            XCTAssertEqual($0 as? LibraryOperationError, .operationsInProgress)
        }
        reader.close()
        let pending = try shared.start(expected: generation) { 42 }
        XCTAssertThrowsError(try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)) {
            XCTAssertEqual($0 as? LibraryOperationError, .operationsInProgress)
        }
        _ = try await pending.value
        var states: [LibraryOperationState] = []
        shared.onStateChanged = { states.append($0) }
        let operation = try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)
        XCTAssertTrue(shared.state.isExclusive)
        XCTAssertThrowsError(try shared.open(expected: generation)) {
            XCTAssertEqual($0 as? LibraryOperationError, .exclusiveInProgress)
        }
        let completion = try await operation.value
        XCTAssertTrue(completion.presentationPublished)
        XCTAssertEqual(completion.report.previewID, preview.id)
        XCTAssertEqual(states.map(\.isExclusive), [false, true, true, false])
        XCTAssertEqual(states[0].presentation, states[1].presentation)
        XCTAssertNotEqual(states[1].presentation, states[2].presentation)
        XCTAssertEqual(states[2].presentation, states[3].presentation)
        XCTAssertNotEqual(try epoch(f), oldEpoch)
        XCTAssertEqual(try f.db.query("SELECT title FROM manga").first?.string("title"), "New")
    }

    @MainActor
    func testRestoreOperationFailureReleasesWithoutPublishingOrChangingEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.execute("CREATE TRIGGER fail_restore BEFORE INSERT ON manga BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new", title: "New")]))
        let shared = LibraryOperationCoordinator(), before = try epoch(f)
        let generation = shared.state.presentation
        let operation = try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)
        await rejects(.storageUnavailable) { _ = try await operation.value }
        XCTAssertFalse(shared.state.isExclusive)
        XCTAssertEqual(shared.state.presentation, generation)
        XCTAssertEqual(try epoch(f), before)
        XCTAssertTrue(try f.db.query("SELECT * FROM manga").isEmpty)
    }

    @MainActor
    func testCancellingQueuedRestorePerformsNoWritesAndReleasesExclusion() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new", title: "New")]))
        let shared = LibraryOperationCoordinator(), before = try epoch(f)
        let generation = shared.state.presentation
        let operation = try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)
        operation.cancel()
        XCTAssertTrue(shared.state.isExclusive)
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(shared.state.isExclusive)
        XCTAssertEqual(shared.state.presentation, generation)
        XCTAssertEqual(try epoch(f), before)
        XCTAssertTrue(try f.db.query("SELECT * FROM manga").isEmpty)
    }

    @MainActor
    func testCancellationDuringCommittedPublicationStillReportsSuccessAndKeepsNewGeneration() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new", title: "New")]))
        let shared = LibraryOperationCoordinator(), before = try epoch(f)
        let generation = shared.state.presentation
        var operation: Task<LibraryRestoreCompletion, Error>?
        shared.onStateChanged = { state in
            if state.isExclusive && state.presentation != generation { operation?.cancel() }
        }
        operation = try shared.startLibraryRestore(store: f.store, preview: preview, expected: generation)
        let result = try await XCTUnwrap(operation).value
        XCTAssertTrue(result.presentationPublished)
        XCTAssertTrue(try XCTUnwrap(operation).isCancelled)
        XCTAssertFalse(shared.state.isExclusive)
        XCTAssertNotEqual(shared.state.presentation, generation)
        XCTAssertNotEqual(try epoch(f), before)
        XCTAssertEqual(try f.db.query("SELECT title FROM manga").first?.string("title"), "New")
        shared.onStateChanged = nil
    }

    @MainActor
    func testCancellingRestoreObserverDoesNotCancelOwnedCommit() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new", title: "New")]))
        let shared = LibraryOperationCoordinator()
        let operation = try shared.startLibraryRestore(store: f.store, preview: preview, expected: shared.state.presentation)
        let observer = Task { try await operation.value }
        observer.cancel()
        let result = try await observer.value
        XCTAssertTrue(result.presentationPublished)
        XCTAssertFalse(operation.isCancelled)
        XCTAssertFalse(shared.state.isExclusive)
        XCTAssertEqual(try f.db.query("SELECT title FROM manga").first?.string("title"), "New")
    }

    func testPreviewIsReadOnlyAndMergePreservesMetadataProgressHistoryCategoriesAndDiscovery() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let (m, c) = try seed(f)
        let category = try f.db.insert("INSERT INTO category(name,sort_order,flags) VALUES ('Reading',7,42)")
        try f.db.run("INSERT INTO manga_category VALUES (?,?)", [.int(m), .int(category)])
        try f.db.run("INSERT INTO history VALUES (?,?,200,1000)", [.int(m), .int(c)])
        try f.db.run("INSERT INTO chapter_discovery_baseline VALUES (?,123)", [.int(m)])
        try f.db.run("INSERT INTO known_chapter VALUES (?,'/c',100,200)", [.int(m)])
        let target = try await readingTargetForTest(store: f.store, mangaID: m, chapterID: c)
        let oldEpoch = try epoch(f), before = try await snapshot(f)
        let input = try bytes([
            .init(sourceID: 7, url: "/m", title: "Archive title", inLibrary: true, categoryKeys: ["a", "b"], chapters: [
                .init(url: "/c", name: "Archive chapter", read: true, lastPageRead: 4),
                .init(url: "/archive", name: "Archive only", read: true, lastPageRead: 9)
            ], history: [.init(chapterURL: "/c", lastRead: 300, readDuration: 500)],
                  discoveryBaseline: .init(establishedAt: 10), knownChapters: [
                    .init(url: "/c", firstSeen: 1, detectedAt: 999),
                    .init(url: "/archive", firstSeen: 15, detectedAt: 1000)
                  ]),
            .init(sourceID: Int64.min, url: "/new", title: "New", inLibrary: true, dateAdded: 11,
                  dateUpdated: 12, lastFetched: 13, initialized: false, categoryKeys: ["b"],
                  chapters: [.init(sourceOrder: 4_294_967_301, url: "/new-c", name: "New chapter", number: 1.25,
                                   dateUpload: 123_456_789_012, dateFetch: 22, lastPageRead: 4_294_967_302)],
                  history: [.init(chapterURL: "/new-c", lastRead: 9, readDuration: 44)])
        ], categories: [.init(key: "a", name: "reading", sortOrder: 100, flags: 99), .init(key: "b", name: "Later", sortOrder: -1, flags: 5)])
        let preview = try await f.store.previewLibraryRestore(from: input)
        XCTAssertEqual(preview.inputSHA256, APKSignatureVerifier.apkSHA256(Array(input)))
        XCTAssertEqual(preview.summary.newManga, 1); XCTAssertEqual(preview.summary.existingManga, 1)
        XCTAssertEqual(preview.summary.newChapters, 2); XCTAssertEqual(preview.summary.newCategories, 1)
        try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
        let report = try await f.store.commitLibraryRestore(preview)
        XCTAssertEqual(report.previewID, preview.id); XCTAssertNotEqual(try epoch(f), oldEpoch)
        let saved = try await f.store.exportBackupSnapshot(exportID: archiveID, exportedAt: 0)
        let old = try XCTUnwrap(saved.manga.first { $0.sourceID == 7 })
        XCTAssertEqual(old.title, "Saved")
        let existing = try XCTUnwrap(old.chapters.first { $0.url == "/c" })
        XCTAssertEqual(existing.name, "Saved chapter"); XCTAssertEqual(existing.number, 2.5)
        XCTAssertTrue(existing.read); XCTAssertTrue(existing.bookmark); XCTAssertEqual(existing.lastPageRead, 8)
        XCTAssertFalse(try XCTUnwrap(old.chapters.first { $0.url == "/archive" }).isCurrent)
        XCTAssertEqual(old.history, [.init(chapterURL: "/c", lastRead: 300, readDuration: 1000)])
        XCTAssertEqual(old.discoveryBaseline?.establishedAt, 123)
        XCTAssertEqual(old.knownChapters.first { $0.url == "/c" }?.detectedAt, 200)
        XCTAssertNil(old.knownChapters.first { $0.url == "/archive" }?.detectedAt)
        let added = try XCTUnwrap(saved.manga.first { $0.sourceID == Int64.min })
        XCTAssertEqual(added.dateAdded, 11); XCTAssertEqual(added.dateUpdated, 12); XCTAssertEqual(added.lastFetched, 13)
        XCTAssertFalse(added.initialized); XCTAssertEqual(added.chapters.first?.lastPageRead, 4_294_967_302)
        XCTAssertEqual(saved.categories.first { $0.name == "Reading" }?.flags, 42)
        XCTAssertEqual(saved.categories.first { $0.name == "Later" }?.sortOrder, 8)
        XCTAssertEqual(old.categoryKeys.count, 2)
        do { _ = try await f.store.validateReadingTarget(target); XCTFail("Retained reader must expire") }
        catch { XCTAssertEqual(error as? ReadingStateError, .staleEpoch) }
        await rejects(.previewExpired) { _ = try await f.store.commitLibraryRestore(preview) }
        let stable = try await snapshot(f)
        let again = try await f.store.previewLibraryRestore(from: input)
        _ = try await f.store.commitLibraryRestore(again)
        try await assertSnapshot(f, equals: stable, "Repeated import must not add duration, duplicates or discoveries")
    }

    func testUnicodeDistinctMangaAndChapterURLsAndSignedSourceIDsRemainSeparate() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let composed = "/caf\u{e9}", decomposed = "/cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        let input = try bytes([
            .init(sourceID: Int64.max, url: composed, chapters: [.init(url: composed, name: "A"), .init(url: decomposed, name: "B")]),
            .init(sourceID: Int64.max, url: decomposed, chapters: [.init(url: "/z", name: "C")])
        ])
        let preview = try await f.store.previewLibraryRestore(from: input)
        _ = try await f.store.commitLibraryRestore(preview)
        let saved = try await f.store.exportBackupSnapshot(exportID: archiveID, exportedAt: 0)
        XCTAssertEqual(Set(saved.manga.map { Data($0.url.utf8) }), Set([Data(composed.utf8), Data(decomposed.utf8)]))
        let first = try XCTUnwrap(saved.manga.first { Data($0.url.utf8) == Data(composed.utf8) })
        XCTAssertEqual(Set(first.chapters.map { Data($0.url.utf8) }).count, 2)
    }

    func testForeignStoreRejectsPreviewEvenForTheSameDatabaseAndEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 7, url: "/new")]))
        let second = try LibraryStore(path: f.directory.appendingPathComponent("library.sqlite").path)
        await rejects(.foreignPreview) { _ = try await second.commitLibraryRestore(preview) }
        XCTAssertTrue(try f.db.query("SELECT id FROM manga").isEmpty)
    }

    func testEveryPersistedDependencyAndExternalABAMakePreviewExpire() async throws {
        let edits = [
            "UPDATE manga SET title='Other'", "UPDATE manga SET library_revision=library_revision+1",
            "UPDATE chapter SET last_page_read=99", "INSERT INTO category(name) VALUES ('New')",
            "INSERT INTO known_chapter VALUES (1,'/known',1,NULL)", "INSERT INTO chapter_discovery_baseline VALUES (1,3)",
            "INSERT INTO history VALUES (1,1,30,40)", "INSERT INTO source_preference VALUES (7,'key','value')",
            "INSERT INTO extension_repo(url,name,added_at,trusted) VALUES ('https://fixture.invalid','Repo',1,0)",
            "INSERT INTO installed_extension(package_name,version_name,version_code,apk_path) VALUES ('test.source','1',1,'missing.apk')",
            "INSERT INTO source_content_binding VALUES (6351052922295965587,'unresolved',NULL,1)",
            "UPDATE category SET id=99 WHERE id=1",
            "UPDATE manga SET title='Temporary'; UPDATE manga SET title='Saved'",
            "UPDATE library_data_state SET epoch=randomblob(16)"
        ]
        for edit in edits {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try seed(f)
            try f.db.execute("INSERT INTO category(name) VALUES ('Existing')")
            let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]))
            try f.db.execute(edit)
            let before = try await snapshot(f), oldEpoch = try epoch(f)
            await rejects(.previewExpired) { _ = try await f.store.commitLibraryRestore(preview) }
            try await assertSnapshot(f, equals: before, edit); XCTAssertEqual(try epoch(f), oldEpoch, edit)
        }
    }

    func testSameConnectionMetadataABAExpiresEvenWhenExportAndDependencyDigestReturnToOriginal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let (id, _) = try seed(f)
        let loaded = try await f.store.manga(id: id)
        var original = try XCTUnwrap(loaded)
        let before = try await snapshot(f)
        let preview = try await f.store.previewLibraryRestore(from: bytes())
        original.title = "Temporary"
        _ = try await f.store.upsert(original)
        original.title = "Saved"
        _ = try await f.store.upsert(original)
        try await assertSnapshot(f, equals: before)
        let fresh = try await f.store.previewLibraryRestore(from: bytes())
        XCTAssertEqual(preview.dependencyDigest, fresh.dependencyDigest)
        await rejects(.previewExpired) { _ = try await f.store.commitLibraryRestore(preview) }
    }

    func testLateWriterFailureRollsBackAllImportedRowsBindingAndEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try seed(f)
        try f.db.execute("CREATE TRIGGER fail_restore_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'injected write failure'); END")
        let before = try await snapshot(f), oldEpoch = try epoch(f)
        let input = try bytes([.init(sourceID: SourceContentBindingPersistence.sourceID, url: "/foo", inLibrary: true,
            categoryKeys: ["a"], chapters: [.init(url: "/c", name: "Imported")], history: [.init(chapterURL: "/c", lastRead: 3)])],
            categories: [.init(key: "a", name: "New category")], sources: [.init(sourceID: SourceContentBindingPersistence.sourceID,
                name: "Foo", contentBinding: .init(kind: .deployment, deploymentURL: "https://fixture.invalid"))])
        let preview = try await f.store.previewLibraryRestore(from: input)
        await rejects(.storageUnavailable) { _ = try await f.store.commitLibraryRestore(preview) }
        try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
        XCTAssertTrue(try f.db.query("SELECT * FROM source_content_binding").isEmpty)
    }

    func testDurableRunningScanAndDownloadPublicationRefuseWithoutRecoveringOwners() async throws {
        let active = [
            "INSERT INTO library_update_scan VALUES ('scan','running',0,NULL,0)",
            "INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,state,revision,queue_order,created_at,updated_at) VALUES ('job',1,1,7,'','',1,1,0,0,0)",
            "INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,state,revision,publication_state,queue_order,created_at,updated_at) VALUES ('job',1,1,7,'','',3,1,'prepared',0,0,0)"
        ]
        for sql in active {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try seed(f); try f.db.execute(sql)
            let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]))
            let before = try await snapshot(f), oldEpoch = try epoch(f)
            await rejects(.activeWork) { _ = try await f.store.commitLibraryRestore(preview) }
            try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
        }
    }

    func testDeploymentConflictsRequireExplicitExclusionAndCannotRebindContent() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let foo = SourceContentBindingPersistence.sourceID
        try f.db.run("INSERT INTO source_content_binding VALUES (?,'deployment','https://original.invalid',1)", [.int(foo)])
        try f.db.run("INSERT INTO manga(source_id,url,title) VALUES (?,'/same','Original')", [.int(foo)])
        let input = try bytes([.init(sourceID: foo, url: "/same", title: "Other deployment"), .init(sourceID: 8, url: "/safe")],
            sources: [.init(sourceID: foo, name: "Foo", contentBinding: .init(kind: .deployment, deploymentURL: "https://different.invalid")),
                      .init(sourceID: 8, name: "Ordinary")])
        let blocked = try await f.store.previewLibraryRestore(from: input)
        XCTAssertFalse(blocked.canRestore); XCTAssertEqual(blocked.summary.excludedManga, 1)
        XCTAssertEqual(blocked.conflicts.first?.storedDeployment, "https://original.invalid")
        await rejects(.sourceConflicts) { _ = try await f.store.commitLibraryRestore(blocked) }
        let allowed = try await f.store.previewLibraryRestore(from: input, excludingConflictedSources: true)
        _ = try await f.store.commitLibraryRestore(allowed)
        XCTAssertEqual(try f.db.query("SELECT deployment_url FROM source_content_binding").first?.string("deployment_url"), "https://original.invalid")
        XCTAssertEqual(try f.db.query("SELECT title FROM manga WHERE source_id=?", [.int(foo)]).first?.string("title"), "Original")
        XCTAssertEqual(try f.db.query("SELECT COUNT(*) AS n FROM manga").first?.int64("n"), 2)
    }

    func testFirstFooRestoreStoresOnlyContentBindingAndUnresolvedContentStaysInert() async throws {
        for binding in [Doc.ContentBinding(kind: .deployment, deploymentURL: "https://fixture.invalid"), .init(kind: .unresolved)] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let foo = SourceContentBindingPersistence.sourceID
            let input = try bytes([.init(sourceID: foo, url: "/m")], sources: [.init(sourceID: foo, name: "Claimed label", contentBinding: binding)])
            let preview = try await f.store.previewLibraryRestore(from: input)
            XCTAssertTrue(preview.canRestore)
            XCTAssertEqual(preview.summary.unresolvedManga, binding.kind == .unresolved ? 1 : 0)
            _ = try await f.store.commitLibraryRestore(preview)
            XCTAssertEqual(try f.db.query("SELECT kind FROM source_content_binding").first?.string("kind"), binding.kind.rawValue)
            XCTAssertTrue(try f.db.query("SELECT * FROM installed_extension").isEmpty)
            XCTAssertTrue(try f.db.query("SELECT * FROM installed_extension_preferences").isEmpty)
            XCTAssertTrue(try f.db.query("SELECT * FROM extension_repo").isEmpty)
            if binding.kind == .unresolved {
                let second = try await f.store.previewLibraryRestore(from: input)
                XCTAssertFalse(second.canRestore, "Populated unresolved namespaces cannot be equated by a missing URL")
            }
        }
    }

    func testPreviewRejectsCombinedLimitsCategoryOrderOverflowAndMalformedStoredMetadata() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try seed(f)
        let policy = try LibraryBackupPolicy(maximumManga: 1)
        await rejects(.resultLimitExceeded) { _ = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]), policy: policy) }
        try f.db.run("INSERT INTO category(name,sort_order) VALUES ('Last',?)", [.int(Int64.max)])
        await rejects(.categoryOrderOverflow) { _ = try await f.store.previewLibraryRestore(from: bytes(categories: [.init(key: "new", name: "Overflow")])) }
        try f.db.execute("INSERT INTO source_preference VALUES (7,'secret','value'); UPDATE source_preference SET value=CAST(X'610062' AS TEXT)")
        await rejects(.invalidStoredData) { _ = try await f.store.previewLibraryRestore(from: bytes()) }
    }

    func testCancellationBeforeCommitPreservesRowsAndEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try seed(f)
        let before = try await snapshot(f), oldEpoch = try epoch(f)
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.commitLibraryRestore(preview)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
    }

    func testPausedDownloadReceiptsCleanupAndInstalledSettingsSurviveAndUnrelatedRowsAreNotWritten() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let (m, c) = try seed(f)
        try f.db.execute("""
            INSERT INTO installed_extension(package_name,version_name,version_code,apk_path,enabled)
                VALUES ('fixture.source','1',1,'missing.apk',0);
            INSERT INTO installed_extension_preferences VALUES ('fixture.source','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,3,'{}');
            INSERT INTO extension_repo(url,name,added_at,trusted) VALUES ('https://fixture.invalid','Saved repo',1,0);
            INSERT INTO source_preference VALUES (7,'saved','value');
            INSERT INTO download_job(job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,
                state,revision,attempt_id,publication_state,page_count,queue_order,created_at,updated_at)
                VALUES ('job',1,1,7,'digest-m','digest-c',3,2,'attempt','none',1,0,1,2);
            INSERT INTO download_page VALUES ('job','attempt',0,20,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
            INSERT INTO download_cleanup VALUES ('old-attempt','old-job',1,1,7,'digest-m','digest-c',20);
            CREATE TRIGGER untouched_manga BEFORE UPDATE ON manga WHEN OLD.source_id=7
                BEGIN SELECT RAISE(ABORT,'unrelated manga touched'); END;
            CREATE TRIGGER untouched_chapter BEFORE UPDATE ON chapter WHEN OLD.manga_id=1
                BEGIN SELECT RAISE(ABORT,'unrelated chapter touched'); END;
            """)
        XCTAssertEqual(m, 1); XCTAssertEqual(c, 1)
        let tables = ["installed_extension", "installed_extension_preferences", "source_preference", "extension_repo",
                      "download_job", "download_page", "download_cleanup"]
        let before = try tables.map { try f.db.restoreDependencyBytes("SELECT * FROM \($0) ORDER BY rowid", maximumRows: 10,
                                                                      maximumColumnBytes: 16_384, maximumBytes: 100_000) }
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]))
        _ = try await f.store.commitLibraryRestore(preview)
        let after = try tables.map { try f.db.restoreDependencyBytes("SELECT * FROM \($0) ORDER BY rowid", maximumRows: 10,
                                                                     maximumColumnBytes: 16_384, maximumBytes: 100_000) }
        XCTAssertEqual(after, before)
    }

    func testPreferenceRevisionAndEnabledChangesExpireRetainedPreview() async throws {
        for edit in ["UPDATE installed_extension SET enabled=1",
                     "UPDATE installed_extension_preferences SET revision=4",
                     "UPDATE installed_extension_preferences SET user_values='{\"value\":true}'; UPDATE installed_extension_preferences SET user_values='{}'"] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            try f.db.execute("""
                INSERT INTO installed_extension(package_name,version_name,version_code,apk_path,enabled) VALUES ('fixture.source','1',1,'missing.apk',0);
                INSERT INTO installed_extension_preferences VALUES ('fixture.source','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,3,'{}');
                """)
            let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 8, url: "/new")]))
            try f.db.execute(edit)
            await rejects(.previewExpired) { _ = try await f.store.commitLibraryRestore(preview) }
            XCTAssertTrue(try f.db.query("SELECT id FROM manga").isEmpty)
        }
    }

    func testEpochPublicationFailureRollsBackDomainWritesAndWriterContentionDoesNotConsumePreview() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try seed(f)
        let input = try bytes([.init(sourceID: 8, url: "/new")])
        let blocked = try await f.store.previewLibraryRestore(from: input)
        try f.db.execute("BEGIN IMMEDIATE")
        await rejects(.storageUnavailable) { _ = try await f.store.commitLibraryRestore(blocked) }
        try f.db.execute("ROLLBACK")
        _ = try await f.store.commitLibraryRestore(blocked)
        try f.db.execute("CREATE TRIGGER fail_epoch AFTER UPDATE ON library_data_state BEGIN SELECT RAISE(ABORT,'epoch failure'); END")
        let before = try await snapshot(f), oldEpoch = try epoch(f)
        let preview = try await f.store.previewLibraryRestore(from: bytes([.init(sourceID: 9, url: "/later")]))
        await rejects(.storageUnavailable) { _ = try await f.store.commitLibraryRestore(preview) }
        try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
    }

    func testReviewedFileBytesRemainImmutableWhenTheProviderFileChanges() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let url = f.directory.appendingPathComponent("backup.json")
        let original = try bytes([.init(sourceID: 7, url: "/original")])
        try original.write(to: url)
        let input = try LibraryBackupFileReader.read(url)
        let preview = try await f.store.previewLibraryRestore(from: input)
        try bytes([.init(sourceID: 7, url: "/replacement")]).write(to: url)
        _ = try await f.store.commitLibraryRestore(preview)
        XCTAssertEqual(try f.db.query("SELECT url FROM manga").first?.string("url"), "/original")
        XCTAssertEqual(preview.inputSHA256, APKSignatureVerifier.apkSHA256(Array(original)))
    }

    func testCombinedChapterHistoryKnownMembershipAndStringLimitsFailBeforeWrites() async throws {
        let policies = [
            try LibraryBackupPolicy(maximumChapters: 1), try LibraryBackupPolicy(maximumHistory: 1),
            try LibraryBackupPolicy(maximumKnownChapters: 1), try LibraryBackupPolicy(maximumMemberships: 1)
        ]
        for policy in policies {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let (m,c) = try seed(f)
            try f.db.run("INSERT INTO history VALUES (?,?,2,3)", [.int(m), .int(c)])
            try f.db.run("INSERT INTO known_chapter VALUES (?,'/c',0,NULL)", [.int(m)])
            try f.db.execute("INSERT INTO category(name) VALUES ('Saved'); INSERT INTO manga_category VALUES (1,1)")
            let input = try bytes([.init(sourceID: 8, url: "/new", inLibrary: true, categoryKeys: ["a"],
                chapters: [.init(url: "/other", name: "Other")], history: [.init(chapterURL: "/other", lastRead: 2)],
                knownChapters: [.init(url: "/other", firstSeen: 1)])], categories: [.init(key: "a", name: "Saved")])
            let before = try await snapshot(f), oldEpoch = try epoch(f)
            await rejects(.resultLimitExceeded) { _ = try await f.store.previewLibraryRestore(from: input, policy: policy) }
            try await assertSnapshot(f, equals: before); XCTAssertEqual(try epoch(f), oldEpoch)
        }
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try f.db.run("INSERT INTO manga(source_id,url,title) VALUES (7,'/m',?)", [.text(String(repeating: "a", count: 100))])
        let input = try bytes([.init(sourceID: 8, url: "/new", title: String(repeating: "b", count: 100))])
        await rejects(.resultLimitExceeded) { _ = try await f.store.previewLibraryRestore(from: input,
            policy: LibraryBackupPolicy(maximumTotalStringBytes: 180)) }
    }

}
#endif
