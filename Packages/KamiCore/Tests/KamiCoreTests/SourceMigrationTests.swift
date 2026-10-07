import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

struct MigrationTestSource: KamiSource {
    var id = MangaDexSource().id
    let name = "Fixture destination"
    let language = "en"
    let baseURL = "https://fixture.invalid"
    var details: @Sendable (SMangaCompat) async throws -> SMangaCompat = { $0 }
    var chapterList: @Sendable () async throws -> [SChapterCompat] = { [.init(url: "/one", name: "One", number: "1")] }
    func getPopularManga(page: Int) async throws -> MangasPageCompat { throw SourceMigrationError.invalidDestination }
    func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat { throw SourceMigrationError.invalidDestination }
    func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { try await details(manga) }
    func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { try await chapterList() }
    func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { throw SourceMigrationError.invalidDestination }
}

@MainActor
func migrationSelection() throws -> SourceDiscoveryStore {
    var data = try SourceDiscoveryPreferences.all.encoded()
    return .init(read: { data }, write: { data = $0 })
}

final class SourceMigrationTests: XCTestCase {
    private typealias Chapter = LibraryBackupDocument.Chapter

    func testMatchesUniqueFractionsWithoutTitleOrURLGuessingAndReportsEveryGap() throws {
        let original: [Chapter] = [
            .init(url: "/a", name: "Unrelated title", number: 1.25, read: true),
            .init(url: "/b", name: "2", number: 2), .init(url: "/c", name: "2 second edition", number: 2),
            .init(url: "/d", name: "Chapter 3", number: -1), .init(url: "/e", name: "4", number: 4),
            .init(url: "/f", name: "5", number: 5), .init(url: "/zero", name: "Prologue", number: 0)
        ]
        let destination: [Chapter] = [
            .init(url: "/new", name: "Different edition", number: 1.25),
            .init(url: "/b", name: "2", number: 2), .init(url: "/d", name: "Chapter 3", number: 3),
            .init(url: "/five", name: "5A", number: 5), .init(url: "/five-b", name: "5B", number: 5),
            .init(url: "/z", name: "Zero", number: 0)
        ]
        let result = try SourceMigrationMatching.prepare(original: original, destination: destination)
        XCTAssertEqual(result.matches.map(\.id), [0, 6])
        XCTAssertEqual(result.matches.map(\.destination.url), ["/new", "/z"])
        XCTAssertEqual(result.unmatched.map(\.reason), [.ambiguousNumber, .ambiguousNumber, .unknownNumber, .noDestination, .ambiguousNumber])
        XCTAssertEqual(result.unmatchedDestinationCount, 4)
        XCTAssertEqual(result.matches.count + result.unmatched.count, original.count)
    }

    func testByteDistinctURLsAreSeparateAndDuplicateURLOrNonfiniteNumberRejects() throws {
        let a = "/caf\u{e9}", b = "/cafe\u{301}"
        XCTAssertEqual(a, b)
        let original: [Chapter] = [.init(url: a, name: "A", number: 1), .init(url: b, name: "B", number: 2)]
        let value = try SourceMigrationMatching.prepare(original: original, destination: original)
        XCTAssertEqual(value.matches.count, 2)
        XCTAssertEqual(Set(value.matches.map { Data($0.destination.url.utf8) }).count, 2)
        XCTAssertThrowsError(try SourceMigrationMatching.prepare(original: original + [original[0]], destination: []))
        for number in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SourceMigrationMatching.prepare(original: [.init(url: "/x", name: "X", number: number)], destination: []))
        }
    }

    func testMaximumChapterCountIsBoundedBeforeIndexing() throws {
        let huge = Array(repeating: Chapter(url: "/x", name: "X"), count: 20_001)
        XCTAssertThrowsError(try SourceMigrationMatching.prepare(original: [], destination: huge))
    }

    @MainActor
    func testCandidateValidatesExactResultURLAndRejectsMalformedAndOversizedData() async throws {
        let selection = try migrationSelection()
        for chapters: [SChapterCompat] in [[], [.init(url: "/x"), .init(url: "/x")],
            [.init(url: "/x", chapterNumber: .infinity)], [.init(url: "/x", dateUpload: -1)],
            [.init(url: String(repeating: "x", count: 4_097))],
            Array(repeating: .init(url: "/x"), count: 20_001)] {
            let source = MigrationTestSource(chapterList: { chapters })
            let registration = SourceRegistrationSnapshot(source: source, revision: 1, origin: .native, scope: .init())
            do {
                _ = try await SourceMigrationCandidate.fetch(registration: registration,
                    manga: .init(url: "/m", title: "Manga"), selection: selection.snapshot())
                XCTFail("Expected invalid destination")
            } catch { XCTAssertEqual(error as? SourceMigrationError, .invalidDestination) }
        }
        let altered = MigrationTestSource(details: { _ in .init(url: "/cafe\u{301}") }, chapterList: {
            XCTFail("Changed identity must stop before chapter request"); return []
        })
        let registration = SourceRegistrationSnapshot(source: altered, revision: 1, origin: .native, scope: .init())
        do {
            _ = try await SourceMigrationCandidate.fetch(registration: registration,
                manga: .init(url: "/caf\u{e9}"), selection: selection.snapshot())
            XCTFail("Unicode normalization cannot rebind a destination")
        } catch { XCTAssertEqual(error as? SourceMigrationError, .invalidDestination) }
    }

    @MainActor
    func testCandidatePreservesFractionalNumberAndIgnoresProviderPageAndHistoryClaims() async throws {
        let selection = try migrationSelection()
        let source = MigrationTestSource(chapterList: {
            [.init(url: "/c", name: "C", chapterNumber: 99, number: "1.125", scanlators: ["Group"], memo: ["read": "true"])]
        })
        let registration = SourceRegistrationSnapshot(source: source, revision: 1, origin: .native, scope: .init())
        let candidate = try await SourceMigrationCandidate.fetch(registration: registration,
            manga: .init(url: "/m", title: "M"), selection: selection.snapshot())
        let chapter = try XCTUnwrap(candidate.manga.chapters.first)
        XCTAssertEqual(chapter.number, 1.125); XCTAssertEqual(chapter.scanlator, "Group")
        XCTAssertFalse(chapter.read); XCTAssertFalse(chapter.bookmark); XCTAssertEqual(chapter.lastPageRead, 0)
        XCTAssertTrue(candidate.manga.history.isEmpty)
    }

    private actor Gate {
        var continuation: CheckedContinuation<SMangaCompat, Never>?
        func wait(arrived: @Sendable () -> Void) async -> SMangaCompat {
            await withCheckedContinuation { continuation = $0; arrived() }
        }
        func release() { continuation?.resume(returning: .init(url: "/m")); continuation = nil }
    }

    @MainActor
    func testSelectionAndRegistrationRevocationCancelProviderAndRetainOwnerUntilDrainage() async throws {
        for revokeSelection in [true, false] {
            let arrived = expectation(description: "Provider active"), cancelled = expectation(description: "Provider cancelled")
            let gate = Gate(), scope = SourceRequestScope(), selection = try migrationSelection()
            let source = MigrationTestSource(details: { _ in
                await withTaskCancellationHandler {
                    await gate.wait { arrived.fulfill() }
                } onCancel: { cancelled.fulfill() }
            }, chapterList: { XCTFail("Revoked details cannot request chapters"); return [] })
            let registration = SourceRegistrationSnapshot(source: source, revision: 1, origin: .native, scope: scope)
            let coordinator = LibraryOperationCoordinator(), snapshot = selection.snapshot()
            let operation = try coordinator.start(expected: coordinator.state.presentation) {
                try await SourceMigrationCandidate.fetch(registration: registration, manga: .init(url: "/m"), selection: snapshot)
            }
            await fulfillment(of: [arrived], timeout: 3)
            if revokeSelection { try selection.save(.none, expectedRevision: snapshot.id) }
            else { scope.revoke() }
            await fulfillment(of: [cancelled], timeout: 3)
            XCTAssertEqual(coordinator.state.activeOperations, 1)
            XCTAssertThrowsError(try coordinator.beginExclusive(expected: coordinator.state.presentation))
            await gate.release()
            do { _ = try await operation.value; XCTFail("Revoked candidate must not publish") }
            catch { XCTAssertTrue(error is CancellationError || error is SourceMigrationError) }
            XCTAssertEqual(coordinator.state.activeOperations, 0)
        }
    }

    @MainActor
    func testExcludedOrRevokedSelectionNeverReachesProvider() async throws {
        let selection = try migrationSelection(), captured = selection.snapshot()
        try selection.save(.none, expectedRevision: captured.id)
        let source = MigrationTestSource(details: { _ in XCTFail("Excluded source queried"); return .init() })
        let registration = SourceRegistrationSnapshot(source: source, revision: 1, origin: .native, scope: .init())
        for snapshot in [captured, selection.snapshot()] {
            do {
                _ = try await SourceMigrationCandidate.fetch(registration: registration, manga: .init(url: "/m"), selection: snapshot)
                XCTFail("Expected source change")
            } catch { XCTAssertEqual(error as? SourceMigrationError, .sourceChanged) }
        }
    }
}
