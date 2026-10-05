import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

final class MihonLibraryImportTests: XCTestCase {
    private let m = "11111111-1111-4111-8111-111111111111"
    private let other = "44444444-4444-4444-a444-444444444444"
    private let c = "22222222-2222-4222-8222-222222222222"
    private let d = "33333333-3333-4333-9333-333333333333"
    private let source: Int64 = 2_499_283_573_021_220_255
    private func v(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        bytes.append(UInt8(value)); return bytes
    }
    private func integer(_ field: Int, _ value: Int64) -> [UInt8] { v(UInt64(field << 3)) + v(UInt64(bitPattern: value)) }
    private func blob(_ field: Int, _ value: [UInt8]) -> [UInt8] { v(UInt64(field << 3 | 2)) + v(UInt64(value.count)) + value }
    private func text(_ field: Int, _ value: String) -> [UInt8] { blob(field, Array(value.utf8)) }
    private func manga(_ id: String? = nil, source: Int64? = nil, fields: [UInt8] = []) -> [UInt8] {
        blob(1, integer(1, source ?? self.source) + text(2, id ?? "/manga/\(m)") + fields)
    }
    private func chapter(_ id: String? = nil, fields: [UInt8] = []) -> [UInt8] {
        blob(16, text(1, id ?? "/chapter/\(c)") + text(2, "Chapter") + fields)
    }
    private func history(_ id: String? = nil, time: Int64 = 12_345, duration: Int64 = 55) -> [UInt8] {
        blob(104, text(1, id ?? "/chapter/\(c)") + integer(2, time) + integer(3, duration))
    }
    private func category(_ name: String, order: Int64, id: Int64 = 99) -> [UInt8] {
        blob(2, text(1, name) + integer(2, order) + integer(3, id))
    }
    private func mapped(_ bytes: [UInt8], policy: LibraryBackupPolicy = .default) throws -> MihonLibraryImport.Result {
        try MihonLibraryImport.decode(Data(bytes), decodingPolicy: .default, policy: policy)
    }
    private func fixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("Tests/backups/\(name)"))
    }

    func testIndependentKotlinRawAndGzipMapExactIdentitiesUnitsCategoriesAndFullWidthValues() throws {
        for suffix in ["pb", "tachibk"] {
            let input = try fixture("kotlin-mangadex-import.\(suffix)")
            let result = try MihonLibraryImport.decode(input, decodingPolicy: .default, policy: .default)
            let row = try XCTUnwrap(result.document.manga.first)
            XCTAssertEqual(row.sourceID, source); XCTAssertEqual(row.url, m)
            XCTAssertEqual(row.title, "Reference default favorite"); XCTAssertTrue(row.inLibrary)
            XCTAssertEqual(row.dateAdded, 1_770_000_012)
            XCTAssertEqual(row.updateStrategy, .onlyFetchOnce); XCTAssertTrue(row.initialized)
            XCTAssertEqual(row.categoryKeys, ["mihon-0", "mihon-1"])
            XCTAssertEqual(result.document.categories.map(\.sortOrder), [7, 4_294_967_301])
            XCTAssertEqual(result.document.categories.map(\.flags), [9, 64])
            XCTAssertEqual(row.chapters.map(\.url), [c, d])
            XCTAssertEqual(row.chapters[0].dateFetch, 1_780_000_000_111)
            XCTAssertEqual(row.chapters[0].dateUpload, 1_779_999_999_999)
            XCTAssertEqual(row.chapters[1].lastPageRead, 4_294_967_311)
            XCTAssertEqual(row.history[0].lastRead, 1_780_009_876)
            XCTAssertEqual(row.history[1].readDuration, 5_000_000_001)
            XCTAssertNil(row.discoveryBaseline); XCTAssertEqual(row.knownChapters.map(\.url), [c, d])
            XCTAssertTrue(row.knownChapters.allSatisfy { $0.detectedAt == nil })
            XCTAssertEqual(result.report.roundedTimestamps, 3)
            XCTAssertEqual(result.report.excludedManga, 0)
            XCTAssertEqual(result.report.coverage.unsupportedOccurrences, 0)
            XCTAssertEqual(result.report.compression, suffix == "pb" ? .rawProtobuf : .gzip)
        }
    }

    func testMappingGrammarRejectsAliasesAndNeverRepairsURLs() throws {
        XCTAssertEqual(MihonLibraryImport.uuid("/manga/\(m)", prefix: "/manga/"), m)
        let invalid = [m, "https://mangadex.org/manga/\(m)", "/title/\(m)", "/manga/123",
                       "/manga/\(m)/", "/manga/\(m)?a=b", "/manga/\(m)#x", " /manga/\(m)",
                       "/manga/%31\(m.dropFirst())", "/manga/\(m)\u{0}", "/Manga/\(m)",
                       "/manga/aaaaaaaa-aaaa-4aaa-8aaa-AAAAAAAAAAAA", "/manga/11111111-1111-6111-8111-111111111111",
                       "/manga/11111111-1111-4111-7111-111111111111", "/manga/\(m)extra"]
        for path in invalid {
            XCTAssertNil(MihonLibraryImport.uuid(path, prefix: "/manga/"), path)
            let result = try mapped(manga(path))
            XCTAssertEqual(result.report.excludedManga, 1, path)
            XCTAssertFalse(result.report.hasImportableData)
            XCTAssertTrue(result.document.manga.isEmpty)
        }
    }

    func testOtherLanguagesUnknownSignedSourcesAndUnsupportedMangaAreExplicitlyExcluded() throws {
        for id in [Int64.min, Int64.max, 4_505_830_566_611_664_829, 6_400_665_728_063_187_402, 4_938_773_340_256_184_018] {
            let result = try mapped(manga(source: id, fields: chapter() + history()))
            XCTAssertEqual(result.report.unsupportedSourceIDs, [id])
            XCTAssertEqual(result.report.excludedManga, 1)
            XCTAssertEqual(result.report.excludedChapters, 1); XCTAssertEqual(result.report.excludedHistory, 1)
            XCTAssertTrue(result.document.sources.isEmpty); XCTAssertTrue(result.document.manga.isEmpty)
        }
    }

    func testDuplicateMangaChapterHistoryPreserveFlagsProgressAndFavoriteWithoutAddingDuration() throws {
        let first = manga(fields: text(3, "First") + integer(100, 0) + chapter(fields: integer(4, 1) + integer(6, 9)) + history(time: 10_000, duration: 900))
        let second = manga(fields: text(3, "Second") + chapter(fields: integer(5, 1) + integer(6, 3)) + history(time: 20_000, duration: 20))
        let result = try mapped(first + second)
        let row = try XCTUnwrap(result.document.manga.first), ch = try XCTUnwrap(row.chapters.first)
        XCTAssertEqual(row.title, "First"); XCTAssertTrue(row.inLibrary)
        XCTAssertTrue(ch.read); XCTAssertTrue(ch.bookmark); XCTAssertEqual(ch.lastPageRead, 9)
        XCTAssertEqual(row.history.first?.lastRead, 20); XCTAssertEqual(row.history.first?.readDuration, 900)
        XCTAssertEqual(result.report.duplicateManga, 1); XCTAssertEqual(result.report.duplicateChapters, 1)
        XCTAssertEqual(result.report.duplicateHistory, 1)
    }

    func testCrossParentChaptersAndDanglingHistoryAreExcludedWithoutInventingRows() throws {
        let result = try mapped(manga(fields: chapter() + history()) + manga("/manga/\(other)", fields: chapter() + history()))
        XCTAssertEqual(result.report.mappedManga, 2); XCTAssertEqual(result.report.excludedChapters, 2)
        XCTAssertEqual(result.report.excludedHistory, 2)
        XCTAssertTrue(result.document.manga.allSatisfy { $0.chapters.isEmpty && $0.history.isEmpty })
        let orphans = try mapped(manga(fields: history() + history(time: 88_000) + history("/bad") + history(time: 0)))
        XCTAssertEqual(orphans.report.excludedHistory, 4); XCTAssertEqual(orphans.report.duplicateHistory, 0)
        XCTAssertEqual(orphans.report.mappedHistory, 0)
    }

    func testHistoryCanResolveAChapterFromAnotherDuplicateAndNeverMatchesByNumber() throws {
        let result = try mapped(manga(fields: history()) + manga(fields: chapter() + chapter("/chapter/\(d)")))
        XCTAssertEqual(result.report.mappedHistory, 1); XCTAssertEqual(result.report.mappedChapters, 2)
        XCTAssertEqual(result.document.manga.first?.history.first?.chapterURL, c)
        let malformed = try mapped(manga(fields: chapter("/chapter/invalid") + history("/chapter/invalid")))
        XCTAssertEqual(malformed.report.excludedChapters, 1); XCTAssertEqual(malformed.report.excludedHistory, 1)
    }

    func testCategoriesUseOrderNormalizeNamesAndRejectAmbiguousOrderOrName() throws {
        let result = try mapped(category(" Reading ", order: 7) + manga(fields: integer(17, 7) + integer(17, 99)))
        XCTAssertEqual(result.document.categories.first?.name, "Reading")
        XCTAssertEqual(result.document.manga.first?.categoryKeys, ["mihon-0"])
        XCTAssertEqual(result.report.normalizedCategories, 1)
        XCTAssertEqual(result.report.issues.first { $0.reason == .categoryReference }?.count, 1)
        for input in [category("A", order: 1) + category("B", order: 1),
                      category("A", order: 1) + category("a", order: 2), category("", order: 0)] {
            XCTAssertThrowsError(try mapped(input)) { XCTAssertEqual($0 as? MihonLibraryImportError, .ambiguousCategories) }
        }
    }

    func testNonfavoriteStaysOutsideLibraryAndTimestampFallbackDoesNotMultiplyOrOverflow() throws {
        let input = category("Saved", order: 7) + manga(fields: integer(100, 0) + integer(17, 7) + integer(107, Int64.max))
        let result = try mapped(input), row = try XCTUnwrap(result.document.manga.first)
        XCTAssertFalse(row.inLibrary); XCTAssertTrue(row.categoryKeys.isEmpty)
        XCTAssertEqual(row.dateAdded, 0)
        XCTAssertEqual(result.report.issues.first { $0.reason == .nonLibraryMembership }?.count, 1)
        let added = try mapped(manga(fields: integer(13, Int64.max)))
        XCTAssertEqual(added.document.manga.first?.dateAdded, Int64.max / 1_000)
        let fallback = try mapped(manga(fields: integer(107, Int64.max)))
        XCTAssertEqual(fallback.document.manga.first?.dateAdded, Int64.max)
    }

    func testOpaqueUnsupportedFieldsAreCountedWithoutBecomingSettingsOrAuthority() throws {
        let input = manga(fields: blob(18, [0xff, 0xff])) + blob(104, [0xff, 0xff])
        let result = try mapped(input)
        XCTAssertGreaterThan(result.report.coverage.unsupportedOccurrences, 0)
        XCTAssertEqual(result.document.sources.map(\.sourceID), [source])
        XCTAssertEqual(result.document.sources.first?.contentBinding.kind, .sourceIdentity)
    }

    func testMalformedNegativeAndOverBudgetInputFailAndCancellationPropagates() async throws {
        for input in [[UInt8(0x80)], manga(fields: integer(13, -1)), manga(fields: chapter(fields: integer(6, -1))),
                      manga(fields: history(duration: -1)), manga(fields: integer(8, 99))] {
            XCTAssertThrowsError(try mapped(input)) { XCTAssertEqual($0 as? MihonLibraryImportError, .invalidData) }
        }
        XCTAssertThrowsError(try mapped(manga(), policy: .init(maximumManga: 0))) {
            XCTAssertEqual($0 as? MihonLibraryImportError, .limitExceeded)
        }
        XCTAssertThrowsError(try mapped(manga(), policy: .init(maximumInputBytes: 1))) {
            XCTAssertEqual($0 as? MihonLibraryImportError, .limitExceeded)
        }
        let data = Data(manga())
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try MihonLibraryImport.decode(data, decodingPolicy: .default, policy: .default) }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    private actor Transport: CompatHTTPTransport {
        nonisolated let sourceID = "mihon-import-fixture"
        var bodies: [String]
        private(set) var requests: [CompatHTTPRequest] = []
        init(_ bodies: [String]) { self.bodies = bodies }
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            guard !bodies.isEmpty else { throw MangaDexSourceError.invalidResponse }
            return .init(finalURL: request.url, statusCode: 200, body: Array(bodies.removeFirst().utf8))
        }
    }

    func testMappedNativeRequestsUseBareUUIDPathsAndOnlyRunAfterExplicitSourceCalls() async throws {
        let transport = Transport([
            "{\"result\":\"ok\",\"data\":{\"id\":\"\(m)\",\"attributes\":{\"title\":{\"en\":\"Fixture\"}}}}",
            "{\"result\":\"ok\",\"volumes\":{\"1\":{\"chapters\":{\"1\":{\"chapter\":\"1\",\"id\":\"\(c)\",\"others\":[\"\(d)\"]}}}}}",
            "{\"result\":\"ok\",\"baseUrl\":\"https://images.invalid\",\"chapter\":{\"hash\":\"fixture\",\"data\":[],\"dataSaver\":[]}}"
        ])
        let native = MangaDexSource(transport: transport)
        let result = try mapped(manga(fields: chapter() + chapter("/chapter/\(d)")))
        let before = await transport.requests
        XCTAssertTrue(before.isEmpty)
        let row = try XCTUnwrap(result.document.manga.first)
        _ = try await native.getMangaDetails(manga: .init(url: row.url))
        let chapters = try await native.getChapterList(manga: .init(url: row.url))
        XCTAssertEqual(chapters.map(\.url), [c])
        _ = try await native.getPageList(chapter: .init(url: try XCTUnwrap(row.chapters.last).url))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { URL(string: $0.url)?.path }, ["/manga/\(m)", "/manga/\(m)/aggregate", "/at-home/server/\(d)"])
        XCTAssertTrue(requests.allSatisfy { URL(string: $0.url)?.host == "api.mangadex.org" })
    }

    #if canImport(SQLite3)
    private func database() throws -> (URL, LibraryStore, SQLiteDatabase) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Mihon-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        return (directory, try LibraryStore(path: path), try SQLiteDatabase(path: path))
    }

    func testStoredCrossParentChapterIsExcludedAndHistoryOnlyBackupCanUseExactSavedChapter() async throws {
        let (directory, store, db) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        try db.run("INSERT INTO manga(source_id,url,title) VALUES (?,?,'Saved')", [.int(source), .text(m)])
        try db.run("INSERT INTO chapter(manga_id,url,name,last_page_read) VALUES (1,?,'Saved chapter',99)", [.text(c)])
        let conflict = try await store.previewMihonRestore(from: Data(manga("/manga/\(other)", fields: chapter() + history())), acknowledgingLimitations: true)
        XCTAssertEqual(conflict.mihonReport?.excludedChapters, 1)
        XCTAssertEqual(conflict.mihonReport?.excludedHistory, 1)
        let input = Data(manga(fields: history(time: 55_999, duration: 123)))
        let preview = try await store.previewMihonRestore(from: input, acknowledgingLimitations: true)
        XCTAssertEqual(preview.mihonReport?.reusedStoredChapters, 1)
        XCTAssertEqual(preview.mihonReport?.mappedChapters, 0)
        XCTAssertEqual(preview.mihonReport?.mappedHistory, 1)
        _ = try await store.commitLibraryRestore(preview)
        XCTAssertEqual(try db.query("SELECT last_read FROM history").first?.int64("last_read"), 55)
        XCTAssertEqual(try db.query("SELECT last_page_read FROM chapter").first?.int64("last_page_read"), 99)
    }

    @MainActor
    func testActualFilePreviewAcknowledgementAndOwnedCommitUseOriginalDigestAndNoSourceOperations() async throws {
        let (directory, store, db) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("backup.tachibk")
        let bytes = try fixture("kotlin-mangadex-import.tachibk"); try bytes.write(to: file)
        let input = try LibraryBackupFileReader.read(file)
        let blocked = try await store.previewMihonRestore(from: input)
        XCTAssertFalse(blocked.canRestore); XCTAssertNotNil(blocked.mihonReport)
        XCTAssertEqual(blocked.inputSHA256, APKSignatureVerifier.apkSHA256(Array(bytes)))
        XCTAssertTrue(try db.query("SELECT * FROM manga").isEmpty)
        do { _ = try await store.commitLibraryRestore(blocked); XCTFail("Review required") }
        catch { XCTAssertEqual(error as? LibraryRestoreError, .importReviewRequired) }
        let preview = try await store.previewMihonRestore(from: input, acknowledgingLimitations: true)
        try Data([255]).write(to: file)
        let shared = LibraryOperationCoordinator(), generation = shared.state.presentation
        let operation = try shared.startLibraryRestore(store: store, preview: preview, expected: generation)
        let completed = try await operation.value
        XCTAssertTrue(completed.presentationPublished); XCTAssertNotEqual(generation, shared.state.presentation)
        XCTAssertEqual(try db.query("SELECT url,date_added FROM manga").first?.string("url"), m)
        XCTAssertEqual(try db.query("SELECT date_added FROM manga").first?.int64("date_added"), 1_770_000_012)
        XCTAssertTrue(try db.query("SELECT * FROM installed_extension").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM source_preference").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM extension_repo").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM download_job").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM known_chapter WHERE detected_at IS NOT NULL").isEmpty)
    }

    func testNativeCollisionPreservesCatalogAndReadingStateAndRepeatImportIsIdempotent() async throws {
        let (directory, store, db) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        try db.run("INSERT INTO manga(source_id,url,title,in_library) VALUES (?,?,'Saved',1)", [.int(source), .text(m)])
        try db.run("INSERT INTO chapter(manga_id,url,name,read,bookmark,last_page_read) VALUES (1,?,'Saved chapter',1,0,99)", [.text(c)])
        let bytes = try fixture("kotlin-mangadex-import.pb")
        _ = try await store.commitLibraryRestore(store.previewMihonRestore(from: bytes, acknowledgingLimitations: true))
        let saved = try await store.exportBackupSnapshot(exportedAt: 0)
        let row = try XCTUnwrap(saved.manga.first)
        XCTAssertEqual(row.title, "Saved"); XCTAssertEqual(row.chapters.first { $0.url == c }?.lastPageRead, 99)
        XCTAssertEqual(row.chapters.first { $0.url == d }?.isCurrent, false)
        let again = try await store.previewMihonRestore(from: bytes, acknowledgingLimitations: true)
        _ = try await store.commitLibraryRestore(again)
        let repeated = try await store.exportBackupSnapshot(exportID: saved.exportID, exportedAt: 0)
        XCTAssertEqual(repeated, saved)
    }

    func testNoSupportedDataCannotCommitAndRetainedMihonPreviewStillExpires() async throws {
        let (directory, store, db) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        let empty = try await store.previewMihonRestore(from: Data(manga(source: 9)), acknowledgingLimitations: true)
        XCTAssertFalse(empty.canRestore)
        do { _ = try await store.commitLibraryRestore(empty); XCTFail("No supported data") }
        catch { XCTAssertEqual(error as? LibraryRestoreError, .importReviewRequired) }
        let preview = try await store.previewMihonRestore(from: Data(manga()), acknowledgingLimitations: true)
        try db.execute("INSERT INTO source_preference VALUES (9,'key','value')")
        do { _ = try await store.commitLibraryRestore(preview); XCTFail("Stale preview") }
        catch { XCTAssertEqual(error as? LibraryRestoreError, .previewExpired) }
        XCTAssertTrue(try db.query("SELECT * FROM manga").isEmpty)
    }

    func testNativeRefreshCanHideAlternateEditionWithoutLosingImportedProgressHistoryOrKnowledge() async throws {
        let (directory, store, _) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try await store.previewMihonRestore(from: fixture("kotlin-mangadex-import.pb"), acknowledgingLimitations: true)
        _ = try await store.commitLibraryRestore(preview)
        try await store.replaceChapters(mangaId: 1, with: [.init(mangaId: 1, url: c, name: "Representative")])
        let after = try await store.exportBackupSnapshot(exportedAt: 0)
        let row = try XCTUnwrap(after.manga.first), alternate = try XCTUnwrap(row.chapters.first { $0.url == d })
        XCTAssertFalse(alternate.isCurrent); XCTAssertTrue(alternate.bookmark)
        XCTAssertEqual(alternate.lastPageRead, 4_294_967_311)
        XCTAssertEqual(row.history.first { $0.chapterURL == d }?.readDuration, 5_000_000_001)
        XCTAssertEqual(Set(row.knownChapters.map(\.url)), Set([c,d]))
        XCTAssertTrue(row.knownChapters.allSatisfy { $0.detectedAt == nil })
    }

    func testMihonCommitRollbackAndForeignPreviewUseTheNativeTransactionBoundary() async throws {
        let (directory, store, db) = try database(); defer { try? FileManager.default.removeItem(at: directory) }
        try db.execute("CREATE TRIGGER fail_history BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        let before = try db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch")
        let preview = try await store.previewMihonRestore(from: fixture("kotlin-mangadex-import.pb"), acknowledgingLimitations: true)
        let stranger = try LibraryStore(path: directory.appendingPathComponent("other.sqlite").path)
        do { _ = try await stranger.commitLibraryRestore(preview); XCTFail("Foreign preview") }
        catch { XCTAssertEqual(error as? LibraryRestoreError, .foreignPreview) }
        do { _ = try await store.commitLibraryRestore(preview); XCTFail("Expected rollback") }
        catch { XCTAssertEqual(error as? LibraryRestoreError, .storageUnavailable) }
        XCTAssertTrue(try db.query("SELECT * FROM manga").isEmpty)
        XCTAssertTrue(try db.query("SELECT * FROM category").isEmpty)
        XCTAssertEqual(try db.query("SELECT epoch FROM library_data_state").first?.bytes("epoch"), before)
    }
    #endif
}
