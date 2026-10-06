import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class GlobalSearchSessionTests: XCTestCase {
    private struct Call: Sendable {
        let sourceID: Int64
        let query: String
        let page: Int
        let filterCount: Int
    }

    private actor Gate {
        var calls: [Call] = []
        var pending: [Int64: CheckedContinuation<MangasPageCompat, Error>] = [:]
        var maximumActive = 0
        let arrived: @Sendable (Call) -> Void

        init(arrived: @escaping @Sendable (Call) -> Void) { self.arrived = arrived }

        func fetch(_ call: Call) async throws -> MangasPageCompat {
            calls.append(call)
            // Deliberately ignores cancellation until explicitly released.
            return try await withCheckedThrowingContinuation { continuation in
                XCTAssertNil(pending[call.sourceID], "Queries must drain before reusing a source")
                pending[call.sourceID] = continuation
                maximumActive = max(maximumActive, pending.count)
                arrived(call)
            }
        }

        func release(_ id: Int64, title: String = "Found") {
            pending.removeValue(forKey: id)?.resume(returning:
                .init(mangas: [.init(url: "/manga/\(id)", title: title)], hasNextPage: false))
        }

        func fail(_ id: Int64) {
            pending.removeValue(forKey: id)?.resume(throwing: FixtureError.failed)
        }
    }

    private enum FixtureError: Error { case failed }

    private struct Source: KamiSource {
        let id: Int64
        var name: String { "Source \(id)" }
        let language = "en"
        let baseURL = "https://fixture.invalid"
        let fetch: @Sendable (Call) async throws -> MangasPageCompat
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            try await fetch(.init(sourceID: id, query: query, page: page, filterCount: filters.count))
        }
        func getPopularManga(page: Int) async throws -> MangasPageCompat {
            XCTFail("A global search must not invoke a feed")
            throw FixtureError.failed
        }
        func getFilterList() -> [SourceFilter] {
            XCTFail("Global search preserves source-owned defaults via empty filters")
            return []
        }
        func refreshFilterList() async throws -> [SourceFilter] {
            XCTFail("Global search must not request dynamic filter metadata")
            return []
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { manga }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { [] }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { [] }
    }

    private func snapshot(_ id: Int64, scope: SourceRequestScope = .init(),
                          fetch: @escaping @Sendable (Call) async throws -> MangasPageCompat) -> SourceRegistrationSnapshot {
        .init(source: Source(id: id, fetch: fetch), revision: 1, origin: .native, scope: scope)
    }

    @MainActor
    func testBoundedFanOutPublishesPartialResultsInSourceOrderAndIsolatesFailures() async throws {
        let first = expectation(description: "First three providers")
        first.expectedFulfillmentCount = 3
        let fourth = expectation(description: "Fourth provider")
        let gate = Gate { call in (call.sourceID <= 3 ? first : fourth).fulfill() }
        let registrations = (1...4).map { id in snapshot(Int64(id)) { try await gate.fetch($0) } }
        let session = GlobalSearchSession()
        let partial = expectation(description: "Partial second-source result")
        session.onChange = { state in
            if state.groups.count == 4, state.groups[1].phase == .loaded,
               state.groups[3].phase == .queued { partial.fulfill() }
        }
        let worker = Task { await session.search(query: "  fox  ", registrations: registrations) }
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(session.state.groups.map(\.sourceID), [1, 2, 3, 4])
        XCTAssertEqual(session.state.groups[3].phase, .queued)
        await gate.release(2)
        await fulfillment(of: [partial, fourth], timeout: 3)
        XCTAssertEqual(session.state.groups[1].matches.first?.title, "Found")
        XCTAssertEqual(session.state.groups[0].phase, .searching)
        await gate.fail(4)
        await gate.release(1)
        await gate.release(3)
        await worker.value
        XCTAssertFalse(session.state.isSearching)
        XCTAssertEqual(session.state.completedSources, 4)
        XCTAssertEqual(session.state.groups.map(\.phase), [.loaded, .loaded, .loaded, .failed])
        let calls = await gate.calls
        let maximum = await gate.maximumActive
        XCTAssertEqual(maximum, 3)
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.query == "fox" && $0.page == 1 && $0.filterCount == 0 })
    }

    @MainActor
    func testNewQueryWaitsForLateCancelledProvidersAndSuppressesOldResults() async throws {
        let oldStarted = expectation(description: "Old query")
        let newStarted = expectation(description: "New query")
        let newQueued = expectation(description: "Replacement state")
        let gate = Gate { call in (call.query == "old" ? oldStarted : newStarted).fulfill() }
        let registration = snapshot(1) { try await gate.fetch($0) }
        let session = GlobalSearchSession()
        session.onChange = { state in
            if state.query == "new", state.groups.first?.phase == .queued { newQueued.fulfill() }
        }
        let old = Task { await session.search(query: "old", registrations: [registration]) }
        await fulfillment(of: [oldStarted], timeout: 3)
        let new = Task { await session.search(query: "new", registrations: [registration]) }
        await fulfillment(of: [newQueued], timeout: 3)
        let before = await gate.calls
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(session.state.groups[0].matches.isEmpty)
        await gate.release(1, title: "Obsolete")
        await fulfillment(of: [newStarted], timeout: 3)
        XCTAssertTrue(session.state.groups[0].matches.isEmpty)
        await gate.release(1, title: "Current")
        await old.value
        await new.value
        XCTAssertEqual(session.state.groups[0].matches.map(\.title), ["Current"])
        let maximum = await gate.maximumActive
        XCTAssertEqual(maximum, 1)
    }

    @MainActor
    func testCancellationKeepsLibraryReservationUntilProviderDrainAndNeverStartsQueuedSource() async throws {
        let started = expectation(description: "Three providers")
        started.expectedFulfillmentCount = 3
        let gate = Gate { _ in started.fulfill() }
        let registrations = (1...4).map { id in snapshot(Int64(id)) { try await gate.fetch($0) } }
        let session = GlobalSearchSession()
        let operations = LibraryOperationCoordinator()
        let presentation = operations.state.presentation
        let worker = try operations.start(expected: presentation) {
            await session.search(query: "fox", registrations: registrations)
        }
        await fulfillment(of: [started], timeout: 3)
        session.cancel()
        worker.cancel()
        XCTAssertFalse(session.state.isSearching)
        XCTAssertTrue(session.state.groups.allSatisfy { $0.phase == .cancelled && $0.matches.isEmpty })
        XCTAssertEqual(operations.state.activeOperations, 1)
        XCTAssertThrowsError(try operations.beginExclusive(expected: presentation))
        for id in 1...3 { await gate.release(Int64(id)) }
        try await worker.value
        let calls = await gate.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(session.state.groups.allSatisfy { $0.matches.isEmpty })
        XCTAssertEqual(operations.state.activeOperations, 0)
        let exclusive = try operations.beginExclusive(expected: presentation)
        try operations.finishExclusive(exclusive)
    }

    @MainActor
    func testCancelFromProgressObserverClearsResultsBeforeAnyProviderStarts() async throws {
        let session = GlobalSearchSession()
        session.onChange = { [weak session] state in
            if state.groups.first?.phase == .searching { session?.cancel(clearResults: true) }
        }
        let registrations = (1...4).map { id in snapshot(Int64(id)) { _ in
            XCTFail("Cancellation must be rechecked after publishing progress")
            throw FixtureError.failed
        } }
        await session.search(query: "fox", registrations: registrations)
        XCTAssertTrue(session.state.groups.isEmpty)
        XCTAssertFalse(session.state.isSearching)
    }

    @MainActor
    func testRapidReplacementSkipsSupersededQueryWhileOriginalProviderDrains() async throws {
        let oldStarted = expectation(description: "Old query")
        let lastStarted = expectation(description: "Last query")
        let middleQueued = expectation(description: "Middle queued")
        let lastQueued = expectation(description: "Last queued")
        let gate = Gate { call in
            XCTAssertNotEqual(call.query, "middle")
            (call.query == "old" ? oldStarted : lastStarted).fulfill()
        }
        let registration = snapshot(1) { try await gate.fetch($0) }
        let session = GlobalSearchSession()
        session.onChange = { state in
            if state.groups.first?.phase == .queued {
                if state.query == "middle" { middleQueued.fulfill() }
                if state.query == "last" { lastQueued.fulfill() }
            }
        }
        let old = Task { await session.search(query: "old", registrations: [registration]) }
        await fulfillment(of: [oldStarted], timeout: 3)
        let middle = Task { await session.search(query: "middle", registrations: [registration]) }
        await fulfillment(of: [middleQueued], timeout: 3)
        let last = Task { await session.search(query: "last", registrations: [registration]) }
        await fulfillment(of: [lastQueued], timeout: 3)
        await gate.release(1)
        await fulfillment(of: [lastStarted], timeout: 3)
        await gate.release(1, title: "Last")
        await old.value
        await middle.value
        await last.value
        let calls = await gate.calls
        XCTAssertEqual(calls.map(\.query), ["old", "last"])
        XCTAssertEqual(session.state.groups[0].matches.first?.title, "Last")
    }

    @MainActor
    func testCancelledParentDrainsWithoutExplicitSessionCancel() async throws {
        let started = expectation(description: "Provider")
        let gate = Gate { _ in started.fulfill() }
        let registration = snapshot(1) { try await gate.fetch($0) }
        let session = GlobalSearchSession()
        let worker = Task { await session.search(query: "fox", registrations: [registration]) }
        await fulfillment(of: [started], timeout: 3)
        worker.cancel()
        await gate.release(1, title: "Late result")
        await worker.value
        XCTAssertEqual(session.state.groups.first?.phase, .cancelled)
        XCTAssertTrue(session.state.groups[0].matches.isEmpty)
        XCTAssertFalse(session.state.isSearching)
    }

    @MainActor
    func testRevokedSnapshotCannotStartOrPublishAndDoesNotHideHealthySources() async throws {
        let started = expectation(description: "Provider")
        let gate = Gate { _ in started.fulfill() }
        let revoked = SourceRequestScope()
        revoked.revoke()
        let active = SourceRequestScope()
        let session = GlobalSearchSession()
        let worker = Task {
            await session.search(query: "fox", registrations: [
                snapshot(1, scope: revoked) { _ in XCTFail("Revoked source started"); throw FixtureError.failed },
                snapshot(2, scope: active) { try await gate.fetch($0) },
                snapshot(3) { _ in .init(mangas: [.init(url: "/m", title: "Healthy")], hasNextPage: false) }
            ])
        }
        await fulfillment(of: [started], timeout: 3)
        active.revoke()
        await gate.release(2)
        await worker.value
        XCTAssertEqual(session.state.groups.map(\.phase), [.unavailable, .unavailable, .loaded])
        XCTAssertTrue(session.state.groups[1].matches.isEmpty)
        XCTAssertEqual(session.state.groups[2].matches.first?.title, "Healthy")
    }

    @MainActor
    func testInputValidationAndBlankQueriesNeverCallSources() async throws {
        let source = snapshot(1) { _ in XCTFail("Invalid query called provider"); throw FixtureError.failed }
        let session = GlobalSearchSession()
        await session.search(query: " \n ", registrations: [source])
        XCTAssertTrue(session.state.groups.isEmpty)
        XCTAssertNil(session.state.inputError)
        await session.search(query: String(repeating: "é", count: 513), registrations: [source])
        XCTAssertEqual(session.state.inputError, .queryTooLong)
        XCTAssertEqual(session.state.query, "")
        await session.search(query: "fox", registrations: [source, source])
        XCTAssertEqual(session.state.inputError, .duplicateSource)
        await session.search(query: "fox", registrations: Array(repeating: source, count: 65))
        XCTAssertEqual(session.state.inputError, .tooManySources)
        XCTAssertFalse(session.state.isSearching)
    }

    @MainActor
    func testResultsPreserveByteDistinctPathsAndSourceIdentityButDiscardHeavyDetails() async throws {
        var manga = SMangaCompat(url: "/café", title: "Original", thumbnailURL: "https://img.invalid/a",
            author: "Author", description: "Do not retain this description", initialized: true)
        manga.memo = ["hidden": "Do not retain this memo"]
        let first = manga
        let source = snapshot(1) { _ in
            .init(mangas: [first, .init(url: "/café", title: "Duplicate"),
                           .init(url: "/cafe\u{301}", title: "Byte distinct")], hasNextPage: false)
        }
        let other = snapshot(2) { _ in .init(mangas: [first], hasNextPage: false) }
        let session = GlobalSearchSession()
        await session.search(query: "fox", registrations: [source, other])
        let results = session.state.groups[0].matches
        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(results[0].id, results[1].id)
        XCTAssertEqual(results.map(\.title), ["Original", "Byte distinct"])
        XCTAssertEqual(session.state.groups[1].matches.count, 1)
        XCTAssertNil(results[0].manga.description)
        XCTAssertTrue(results[0].manga.memo.isEmpty)
        XCTAssertFalse(results[0].manga.initialized)
        XCTAssertEqual(results[0].manga.author, "Author")
        XCTAssertFalse(session.state.groups[0].hasMore)
    }

    @MainActor
    func testPreviewCapAndSourcePaginationRemainExplicit() async throws {
        let session = GlobalSearchSession()
        await session.search(query: "fox", registrations: [snapshot(1) { _ in
            .init(mangas: (0..<25).map { .init(url: "/\($0)", title: "Result \($0)") }, hasNextPage: false)
        }, snapshot(2) { _ in .init(mangas: [], hasNextPage: true) }])
        XCTAssertEqual(session.state.groups[0].matches.count, 20)
        XCTAssertEqual(session.state.groups[0].matches.last?.url, "/19")
        XCTAssertTrue(session.state.groups.allSatisfy(\.hasMore))
    }

    @MainActor
    func testOversizedOrMalformedResultsFailOnlyTheirSource() async throws {
        let pages: [[SMangaCompat]] = [
            Array(repeating: .init(url: "/a"), count: 501), [.init(url: "")],
            [.init(url: String(repeating: "x", count: 8_193))],
            [.init(url: "/a", title: String(repeating: "é", count: 2_049))],
            [.init(url: "/a", thumbnailURL: String(repeating: "x", count: 8_193))],
            [.init(url: "/a", author: String(repeating: "x", count: 4_097))],
            (0..<20).map { .init(url: "/\($0)" + String(repeating: "x", count: 8_000),
                                 thumbnailURL: String(repeating: "y", count: 8_000)) }
        ]
        for page in pages {
            let session = GlobalSearchSession()
            await session.search(query: "fox", registrations: [snapshot(1) { _ in
                .init(mangas: page, hasNextPage: false)
            }, snapshot(2) { _ in .init(mangas: [.init(url: "/a", title: "Fine")], hasNextPage: false) }])
            XCTAssertEqual(session.state.groups.map(\.phase), [.failed, .loaded])
            XCTAssertTrue(session.state.groups[0].matches.isEmpty)
            XCTAssertEqual(session.state.groups[1].matches.count, 1)
        }
    }
}
