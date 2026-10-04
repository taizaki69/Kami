import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

#if canImport(SQLite3)

final class LibraryUpdateServiceTests: XCTestCase {
    private actor Gate {
        let entered: XCTestExpectation
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            if open { return }
            entered.fulfill()
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor Probe {
        private(set) var calls: [(sourceID: Int64, url: String)] = []
        private(set) var inputs: [UpdateStrategy] = []
        private(set) var activeBySource: [Int64: Int] = [:]
        private(set) var maximumBySource: [Int64: Int] = [:]
        private(set) var maximumTotal = 0
        func begin(sourceID: Int64, manga: SMangaCompat) {
            calls.append((sourceID, manga.url))
            inputs.append(manga.updateStrategy)
            activeBySource[sourceID, default: 0] += 1
            maximumBySource[sourceID] = max(maximumBySource[sourceID, default: 0], activeBySource[sourceID, default: 0])
            maximumTotal = max(maximumTotal, activeBySource.values.reduce(0, +))
        }
        func end(sourceID: Int64) { activeBySource[sourceID, default: 0] -= 1 }
    }

    private struct Source: KamiSource {
        let id: Int64
        let probe: Probe
        let operation: @Sendable (SMangaCompat) async throws -> SMangaUpdateCompat
        let name = "Offline library source"
        let language = "en"
        let baseURL = "https://offline.invalid"
        func getPopularManga(page: Int) async throws -> MangasPageCompat { throw FakeFailure.unexpectedAPI }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            throw FakeFailure.unexpectedAPI
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { throw FakeFailure.unexpectedAPI }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { throw FakeFailure.unexpectedAPI }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { throw FakeFailure.unexpectedAPI }
        func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
            await probe.begin(sourceID: id, manga: manga)
            do {
                let result = try await operation(manga)
                await probe.end(sourceID: id)
                return result
            } catch {
                await probe.end(sourceID: id)
                throw error
            }
        }
    }

    private enum FakeFailure: Error, LocalizedError {
        case request, unexpectedAPI
        var errorDescription: String? { "secret https://offline.invalid/request?token=private" }
    }

    /// Simulates the already-authenticated persistence seam for coordination.
    /// Real-store tests below separately enforce source-token authority and
    /// baseline/discovery semantics without constructing a transport.
    private actor Ledger: LibraryUpdatePersisting {
        private enum Outcome {
            case checked(new: Int, baseline: Bool)
            case skipped(LibraryUpdateTargetReason)
            case failed(LibraryUpdateTargetReason)
            case cancelled
        }
        private let items: [LibraryUpdateItem]
        private var current: LibraryUpdateSummary?
        private var outcomes: [Int64: Outcome] = [:]
        private var baselines = Set<Int64>()
        private var known: [Int64: Set<String>] = [:]
        private var staleSources = Set<Int64>()
        private var remainingFinishFailures = 0
        private var failCommit = false
        private(set) var successfulManga: [Manga] = []
        private(set) var begins = 0
        private(set) var recoveries = 0
        private let beginGate: Gate?
        init(items: [LibraryUpdateItem], beginGate: Gate? = nil) {
            self.items = items
            self.beginGate = beginGate
            baselines = Set(items.filter(\.hasSuccessfulBaseline).compactMap(\.manga.id))
        }
        func makeSourceStale(_ sourceID: Int64) { staleSources.insert(sourceID) }
        func failNextTerminalWrites(_ count: Int) { remainingFinishFailures = count }
        func setCommitFailure(_ value: Bool) { failCommit = value }
        func recoverInterruptedLibraryUpdateScans() -> LibraryUpdateSummary? {
            recoveries += 1
            if let previous = current, previous.status == .running {
                for id in items.compactMap(\.manga.id) where outcomes[id] == nil { outcomes[id] = .cancelled }
                let counts = recount()
                current = LibraryUpdateSummary(scanID: counts.scanID, status: .interrupted,
                    startedAt: counts.startedAt, finishedAt: 2, total: counts.total, checked: counts.checked,
                    newChapters: counts.newChapters, baselines: counts.baselines, skipped: counts.skipped,
                    failed: counts.failed, cancelled: counts.cancelled)
            }
            return current
        }
        func beginLibraryUpdateScan() async throws -> LibraryUpdateScanSnapshot {
            if current?.status == .running { throw LibraryUpdatePersistenceError.scanAlreadyRunning }
            begins += 1
            if let beginGate { await beginGate.wait() }
            outcomes = [:]
            current = LibraryUpdateSummary(scanID: UUID(), status: .running, startedAt: 1, finishedAt: nil,
                total: items.count, checked: 0, newChapters: 0, baselines: 0, skipped: 0, failed: 0, cancelled: 0)
            let captured = items.map {
                LibraryUpdateItem(manga: $0.manga, hasSuccessfulBaseline: $0.manga.id.map(baselines.contains) ?? false)
            }
            return LibraryUpdateScanSnapshot(record: current!, items: captured)
        }
        func libraryUpdateTargetIsCurrent(scanID: UUID, mangaID: Int64) throws -> Bool {
            try check(scanID)
            return outcomes[mangaID] == nil
        }
        func verifyLibraryUpdateSourceConfiguration(sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?) throws {
            if staleSources.contains(sourceID) { throw ExtensionPreferencesError.staleConfiguration }
        }
        func recordLibraryUpdateSuccess(scanID: UUID, manga: Manga, chapters: [SChapterCompat],
                                       expectedConfiguration: ExtensionExecutionConfiguration?) throws -> LibraryUpdateCommitResult {
            try check(scanID)
            try verifyLibraryUpdateSourceConfiguration(sourceID: manga.sourceId, expectedConfiguration: expectedConfiguration)
            if failCommit { throw SQLiteDatabase.SQLiteError.step("private path", sql: "secret fixture") }
            let id = try XCTUnwrap(manga.id)
            let establish = !baselines.contains(id)
            let urls = Set(chapters.map(\.url))
            let new = establish ? 0 : urls.subtracting(known[id, default: []]).count
            baselines.insert(id)
            known[id, default: []].formUnion(urls)
            successfulManga.append(manga)
            outcomes[id] = .checked(new: new, baseline: establish)
            return LibraryUpdateCommitResult(summary: recount(),
                outcome: .updated(newChapters: new, establishedBaseline: establish))
        }
        func recordLibraryUpdateSkip(scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason) throws -> LibraryUpdateSummary {
            try check(scanID)
            outcomes[mangaID] = .skipped(reason)
            return recount()
        }
        func recordLibraryUpdateFailure(scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason) throws -> LibraryUpdateSummary {
            try check(scanID)
            outcomes[mangaID] = .failed(reason)
            return recount()
        }
        func finishLibraryUpdateScan(scanID: UUID, status: LibraryUpdateScanStatus) throws -> LibraryUpdateSummary {
            guard current?.scanID == scanID else { throw LibraryUpdatePersistenceError.scanNotFound }
            if let current, current.status != .running { return current }
            if remainingFinishFailures > 0 {
                remainingFinishFailures -= 1
                throw SQLiteDatabase.SQLiteError.step("private path", sql: "secret fixture")
            }
            if status == .completed, outcomes.count != items.count { throw LibraryUpdatePersistenceError.unfinishedTargets }
            if status == .cancelled {
                for id in items.compactMap(\.manga.id) where outcomes[id] == nil { outcomes[id] = .cancelled }
            }
            let counts = recount()
            current = LibraryUpdateSummary(scanID: scanID, status: status, startedAt: counts.startedAt, finishedAt: 2,
                total: counts.total, checked: counts.checked, newChapters: counts.newChapters, baselines: counts.baselines,
                skipped: counts.skipped, failed: counts.failed, cancelled: counts.cancelled)
            return current!
        }
        func reason(_ mangaID: Int64) -> LibraryUpdateTargetReason? {
            switch outcomes[mangaID] {
            case let .skipped(reason), let .failed(reason): reason
            case .cancelled: .cancelled
            default: nil
            }
        }
        private func check(_ scanID: UUID) throws {
            guard current?.scanID == scanID else { throw LibraryUpdatePersistenceError.scanNotFound }
            guard current?.status == .running else { throw LibraryUpdatePersistenceError.scanNotRunning }
        }
        private func recount() -> LibraryUpdateSummary {
            var checked = 0, new = 0, baseline = 0, skipped = 0, failed = 0, cancelled = 0
            for outcome in outcomes.values {
                switch outcome {
                case let .checked(count, first): checked += 1; new += count; baseline += first ? 1 : 0
                case .skipped: skipped += 1
                case .failed: failed += 1
                case .cancelled: cancelled += 1
                }
            }
            let previous = current!
            current = LibraryUpdateSummary(scanID: previous.scanID, status: previous.status, startedAt: previous.startedAt,
                finishedAt: previous.finishedAt, total: previous.total, checked: checked, newChapters: new,
                baselines: baseline, skipped: skipped, failed: failed, cancelled: cancelled)
            return current!
        }
    }

    private func item(_ id: Int64, sourceID: Int64, baseline: Bool = false,
                      strategy: UpdateStrategy = .alwaysUpdate) -> LibraryUpdateItem {
        LibraryUpdateItem(manga: Manga(id: id, sourceId: sourceID, url: "/manga/\(id)", title: "Manga \(id)",
            inLibrary: true, updateStrategy: strategy), hasSuccessfulBaseline: baseline)
    }
    private func finished(_ run: LibraryUpdateRun) async throws -> LibraryUpdateProgress {
        var last: LibraryUpdateProgress?
        for await progress in run.updates { last = progress }
        return try XCTUnwrap(last)
    }
    private func emptySource(_ id: Int64, probe: Probe) -> Source {
        Source(id: id, probe: probe) { .init(manga: $0, chapters: []) }
    }

    func testDistinctSourcesAreBoundedAndMangaWithinOneSourceStaySerial() async throws {
        let entered = expectation(description: "Three distinct sources entered")
        entered.expectedFulfillmentCount = 3
        let gate = Gate(entered)
        let probe = Probe()
        let ids = [Int64(100), 101, 102, 103]
        let items = ids.enumerated().flatMap { index, id in
            [item(Int64(index * 2 + 1), sourceID: id), item(Int64(index * 2 + 2), sourceID: id)]
        }
        let ledger = Ledger(items: items)
        let service = LibraryUpdateService(persistence: ledger, maximumConcurrentSources: 999)
        var contexts: [Int64: LibraryUpdateSourceContext] = [:]
        for id in ids {
            let source = Source(id: id, probe: probe) { manga in
                if manga.url.hasSuffix("1") || manga.url.hasSuffix("3") || manga.url.hasSuffix("5") {
                    await gate.wait()
                }
                return .init(manga: manga, chapters: [])
            }
            contexts[id] = .available(source: source, expectedConfiguration: nil)
        }
        let run = try await service.start(sources: contexts)
        await fulfillment(of: [entered], timeout: 5)
        let started = await probe.calls
        XCTAssertEqual(started.count, 3)
        await gate.release()
        let result = try await finished(run)
        let maximum = await probe.maximumTotal
        let perSource = await probe.maximumBySource
        let calls = await probe.calls
        XCTAssertEqual(maximum, 3)
        XCTAssertTrue(perSource.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(calls.count, 8)
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.summary.checked, 8)
        XCTAssertEqual(result.summary.baselines, 8)
        XCTAssertEqual(result.summary.status, .completed)
        XCTAssertEqual(result.inFlight, 0)
        XCTAssertEqual(result.queued, 0)
    }

    func testCancelClosesTokenBeforeLateResponseAndKeepsAlreadyCommittedManga() async throws {
        let entered = expectation(description: "Second manga waiting")
        let gate = Gate(entered)
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10), item(3, sourceID: 10)])
        let service = LibraryUpdateService(persistence: ledger)
        let source = Source(id: 10, probe: probe) { manga in
            if manga.url == "/manga/2" { await gate.wait() }
            return .init(manga: manga, chapters: [.init(url: "\(manga.url)/chapter", name: "Chapter")])
        }
        let contexts: [Int64: LibraryUpdateSourceContext] = [10: .available(source: source, expectedConfiguration: nil)]
        let run = try await service.start(sources: contexts)
        await fulfillment(of: [entered], timeout: 5)
        await service.cancel()
        do {
            _ = try await service.start(sources: contexts)
            XCTFail("Cancelled work must drain before a second scan consumes more source slots")
        } catch { XCTAssertEqual(error as? LibraryUpdateServiceError, .alreadyRunning) }
        await gate.release() // The fake deliberately ignores cancellation.
        let result = try await finished(run)
        let stored = await ledger.successfulManga
        let calls = await probe.calls
        XCTAssertEqual(stored.map(\.id), [1])
        XCTAssertEqual(calls.map(\.url), ["/manga/1", "/manga/2"])
        XCTAssertEqual(result.summary.status, .cancelled)
        XCTAssertEqual(result.summary.checked, 1)
        XCTAssertEqual(result.summary.cancelled, 2)
        XCTAssertEqual(result.summary.newChapters, 0)
        XCTAssertEqual(result.summary.processedCount, result.summary.total)
        XCTAssertNil(result.error)
    }

    func testDuplicateStartAndCancellationDuringBeginNeverInvokeSource() async throws {
        let entered = expectation(description: "Capturing library snapshot")
        let gate = Gate(entered)
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10)], beginGate: gate)
        let service = LibraryUpdateService(persistence: ledger)
        let contexts: [Int64: LibraryUpdateSourceContext] = [10: .available(source: emptySource(10, probe: probe), expectedConfiguration: nil)]
        let preparing = Task { try await service.start(sources: contexts) }
        await fulfillment(of: [entered], timeout: 5)
        do {
            _ = try await service.start(sources: contexts)
            XCTFail("A second start must not capture another scan")
        } catch { XCTAssertEqual(error as? LibraryUpdateServiceError, .alreadyRunning) }
        await service.cancel()
        await gate.release()
        let run = try await preparing.value
        let result = try await finished(run)
        let calls = await probe.calls
        let begins = await ledger.begins
        let recoveries = await ledger.recoveries
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(result.summary.status, .cancelled)
        XCTAssertEqual(result.summary.cancelled, 2)
        _ = try await service.prepare()
        let repeatedRecoveries = await ledger.recoveries
        XCTAssertEqual(repeatedRecoveries, 1)
    }

    func testRequestFailureIsIsolatedAndNeverPublishesSourceErrorText() async throws {
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10), item(3, sourceID: 20)])
        let service = LibraryUpdateService(persistence: ledger)
        let failing = Source(id: 10, probe: probe) { manga in
            if manga.url == "/manga/1" { throw FakeFailure.request }
            return .init(manga: manga, chapters: [])
        }
        let run = try await service.start(sources: [
            10: .available(source: failing, expectedConfiguration: nil),
            20: .available(source: emptySource(20, probe: probe), expectedConfiguration: nil)
        ])
        let result = try await finished(run)
        let reason = await ledger.reason(1)
        let calls = await probe.calls
        XCTAssertEqual(result.summary.status, .completed)
        XCTAssertEqual(result.summary.failed, 1)
        XCTAssertEqual(result.summary.checked, 2)
        XCTAssertEqual(reason, .requestFailed)
        XCTAssertEqual(calls.count, 3)
        XCTAssertNil(result.error)
        XCTAssertFalse(String(describing: result).contains("private"))
        XCTAssertFalse(String(describing: result).contains("offline.invalid"))
    }

    func testRevokedFacadeDiscardsLateResultAndSkipsRemainingMangaForThatSource() async throws {
        let entered = expectation(description: "Old facade request started")
        let gate = Gate(entered)
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10), item(3, sourceID: 20)])
        let service = LibraryUpdateService(persistence: ledger)
        let scope = SourceRequestScope()
        let source = Source(id: 10, probe: probe) { manga in
            await gate.wait()
            return .init(manga: manga, chapters: [.init(url: "/late", name: "Late")])
        }
        let facade = RegisteredSource(source: source, scope: scope,
            fallbackReport: InterpretedCompatibilityRecorder(packageName: "test.offline", versionName: "1", versionCode: 1).report())
        let run = try await service.start(sources: [
            10: .available(source: facade, expectedConfiguration: nil),
            20: .available(source: emptySource(20, probe: probe), expectedConfiguration: nil)
        ])
        await fulfillment(of: [entered], timeout: 5)
        scope.revoke()
        await gate.release()
        let result = try await finished(run)
        let stored = await ledger.successfulManga
        let failed = await ledger.reason(1)
        let skipped = await ledger.reason(2)
        let calls = await probe.calls
        XCTAssertEqual(stored.map(\.sourceId), [20])
        XCTAssertEqual(calls.filter { $0.sourceID == 10 }.count, 1)
        XCTAssertEqual(result.summary.checked, 1)
        XCTAssertEqual(result.summary.failed, 1)
        XCTAssertEqual(result.summary.skipped, 1)
        XCTAssertEqual(result.summary.cancelled, 0)
        XCTAssertEqual(failed, .configurationChanged)
        XCTAssertEqual(skipped, .configurationChanged)
    }

    func testConfigurationChangedAfterRequestPreflightCannotCommitOldResult() async throws {
        let entered = expectation(description: "Old configuration request started")
        let gate = Gate(entered)
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10)])
        let service = LibraryUpdateService(persistence: ledger)
        let source = Source(id: 10, probe: probe) { manga in
            await gate.wait()
            return .init(manga: manga, chapters: [.init(url: "/old", name: "Old")])
        }
        let run = try await service.start(sources: [10: .available(source: source, expectedConfiguration: nil)])
        await fulfillment(of: [entered], timeout: 5)
        await ledger.makeSourceStale(10)
        await gate.release()
        let result = try await finished(run)
        let stored = await ledger.successfulManga
        let calls = await probe.calls
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.summary.failed, 1)
        XCTAssertEqual(result.summary.skipped, 1)
        XCTAssertEqual(result.summary.checked, 0)
        XCTAssertEqual(result.summary.newChapters, 0)
    }

    func testRealStoreFirstBaselineThenSecondScanDiscoversOnlyNewChapter() async throws {
        let store = try LibraryStore(inMemory: true)
        let sourceID = MangaDexSource().id
        _ = try await store.upsert(Manga(sourceId: sourceID, url: "/series", title: "Series", inLibrary: true))
        let probe = Probe()
        let source = Source(id: sourceID, probe: probe) { manga in
            let count = await probe.calls.count
            var chapters = [SChapterCompat(url: "/historical", name: "Historical")]
            if count > 1 { chapters.append(.init(url: "/new", name: "New")) }
            return .init(manga: manga, chapters: chapters)
        }
        let service = LibraryUpdateService(store: store)
        let contexts: [Int64: LibraryUpdateSourceContext] = [sourceID: .available(source: source, expectedConfiguration: nil)]
        let first = try await finished(service.start(sources: contexts))
        let historical = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(first.summary.checked, 1)
        XCTAssertEqual(first.summary.baselines, 1)
        XCTAssertEqual(first.summary.newChapters, 0)
        XCTAssertTrue(historical.discoveries.isEmpty)
        let second = try await finished(service.start(sources: contexts))
        let snapshot = try await store.libraryUpdatesSnapshot()
        XCTAssertEqual(second.summary.checked, 1)
        XCTAssertEqual(second.summary.baselines, 0)
        XCTAssertEqual(second.summary.newChapters, 1)
        XCTAssertEqual(snapshot.discoveries.map(\.chapter.url), ["/new"])
        XCTAssertEqual(snapshot.latestScan, second.summary)
    }

    func testEmptyBaselinePersistsReturnedOnlyFetchOnceStrategyAndSkipsLaterScan() async throws {
        let store = try LibraryStore(inMemory: true)
        let sourceID = MangaDexSource().id
        let id = try await store.upsert(Manga(sourceId: sourceID, url: "/once", title: "Once", inLibrary: true))
        let probe = Probe()
        let source = Source(id: sourceID, probe: probe) { manga in
            var result = manga
            result.updateStrategy = .onlyFetchOnce
            return .init(manga: result, chapters: [])
        }
        let service = LibraryUpdateService(store: store)
        let contexts: [Int64: LibraryUpdateSourceContext] = [sourceID: .available(source: source, expectedConfiguration: nil)]
        let first = try await finished(service.start(sources: contexts))
        let stored = try await store.manga(id: id)
        let second = try await finished(service.start(sources: contexts))
        let calls = await probe.calls
        XCTAssertEqual(first.summary.baselines, 1)
        XCTAssertEqual(first.summary.checked, 1)
        XCTAssertEqual(stored?.updateStrategy, .onlyFetchOnce)
        XCTAssertEqual(second.summary.checked, 0)
        XCTAssertEqual(second.summary.skipped, 1)
        XCTAssertEqual(calls.count, 1)
        let issues = try await store.libraryUpdatesSnapshot().latestScanIssues
        XCTAssertEqual(issues.first?.reason, .onlyFetchOnce)
    }

    func testOnlyFetchOnceWithoutBaselineStillRunsAndCarriesIncomingStrategy() async throws {
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10, strategy: .onlyFetchOnce),
                                    item(2, sourceID: 10, baseline: true, strategy: .onlyFetchOnce)])
        let service = LibraryUpdateService(persistence: ledger)
        let result = try await finished(service.start(sources: [
            10: .available(source: emptySource(10, probe: probe), expectedConfiguration: nil)
        ]))
        let calls = await probe.calls
        let strategies = await probe.inputs
        XCTAssertEqual(calls.map(\.url), ["/manga/1"])
        XCTAssertEqual(strategies, [.onlyFetchOnce])
        XCTAssertEqual(result.summary.checked, 1)
        XCTAssertEqual(result.summary.baselines, 1)
        XCTAssertEqual(result.summary.skipped, 1)
    }

    func testUnavailableMissingConfigurationAndMismatchedSourcesNeverRun() async throws {
        let store = try LibraryStore(inMemory: true)
        let nativeID = MangaDexSource().id
        for sourceID in [nativeID, 10, 20, 30, 40] {
            _ = try await store.upsert(Manga(sourceId: sourceID, url: "/series", title: "Series", inLibrary: true))
        }
        let probe = Probe()
        let service = LibraryUpdateService(store: store)
        let contexts: [Int64: LibraryUpdateSourceContext] = [
            nativeID: .available(source: emptySource(nativeID, probe: probe), expectedConfiguration: nil),
            20: .configurationUnavailable,
            30: .available(source: emptySource(999, probe: probe), expectedConfiguration: nil),
            40: .available(source: emptySource(40, probe: probe), expectedConfiguration: nil)
        ]
        let result = try await finished(service.start(sources: contexts))
        let calls = await probe.calls
        XCTAssertEqual(calls.map(\.sourceID), [nativeID])
        XCTAssertEqual(result.summary.checked, 1)
        XCTAssertEqual(result.summary.skipped, 4)
        XCTAssertEqual(result.summary.failed, 0)
        let issues = try await store.libraryUpdatesSnapshot().latestScanIssues
        XCTAssertEqual(issues.filter { $0.reason == .sourceUnavailable }.count, 1)
        XCTAssertEqual(issues.filter { $0.reason == .configurationChanged }.count, 3)
    }

    func testMangaRemovedWhileQueuedIsSkippedWithoutCallingItsSource() async throws {
        let store = try LibraryStore(inMemory: true)
        let sourceID = MangaDexSource().id
        _ = try await store.upsert(Manga(sourceId: sourceID, url: "/first", title: "A", inLibrary: true))
        let removed = try await store.upsert(Manga(sourceId: sourceID, url: "/second", title: "B", inLibrary: true))
        let entered = expectation(description: "First manga waiting")
        let gate = Gate(entered)
        let probe = Probe()
        let source = Source(id: sourceID, probe: probe) { manga in
            await gate.wait()
            return .init(manga: manga, chapters: [])
        }
        let service = LibraryUpdateService(store: store)
        let run = try await service.start(sources: [sourceID: .available(source: source, expectedConfiguration: nil)])
        await fulfillment(of: [entered], timeout: 5)
        try await store.setLibrary(false, mangaId: removed)
        await gate.release()
        let result = try await finished(run)
        let calls = await probe.calls
        XCTAssertEqual(calls.map(\.url), ["/first"])
        XCTAssertEqual(result.summary.checked, 1)
        XCTAssertEqual(result.summary.skipped, 1)
        let issues = try await store.libraryUpdatesSnapshot().latestScanIssues
        XCTAssertEqual(issues.first?.reason, .removedFromLibrary)
    }

    func testCommitStorageFailureIsNotReportedAsSourceRequestFailure() async throws {
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10), item(2, sourceID: 10)])
        await ledger.setCommitFailure(true)
        let service = LibraryUpdateService(persistence: ledger)
        let contexts: [Int64: LibraryUpdateSourceContext] = [
            10: .available(source: emptySource(10, probe: probe), expectedConfiguration: nil)
        ]
        let result = try await finished(service.start(sources: contexts))
        let calls = await probe.calls
        let saved = await ledger.successfulManga
        XCTAssertEqual(result.error, .storageUnavailable)
        XCTAssertEqual(result.summary.status, .cancelled)
        XCTAssertEqual(result.summary.failed, 0)
        XCTAssertEqual(result.summary.cancelled, 2)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(result.error?.localizedDescription.contains("secret") ?? true)
        await ledger.setCommitFailure(false)
        let retried = try await finished(service.start(sources: contexts))
        XCTAssertEqual(retried.summary.status, .completed)
        XCTAssertEqual(retried.summary.checked, 2)
        XCTAssertNil(retried.error)
    }

    func testTwoFailedTerminalWritesAllowExplicitRecoveryAndNextStart() async throws {
        let probe = Probe()
        let ledger = Ledger(items: [item(1, sourceID: 10)])
        await ledger.failNextTerminalWrites(2)
        let service = LibraryUpdateService(persistence: ledger)
        let contexts: [Int64: LibraryUpdateSourceContext] = [
            10: .available(source: emptySource(10, probe: probe), expectedConfiguration: nil)
        ]
        let failed = try await finished(service.start(sources: contexts))
        XCTAssertEqual(failed.phase, .finished)
        XCTAssertEqual(failed.summary.status, .running, "Do not claim a terminal record was stored when both writes failed")
        XCTAssertEqual(failed.error, .storageUnavailable)
        let recovered = try await service.prepare()
        XCTAssertEqual(recovered?.scanID, failed.scanID)
        XCTAssertEqual(recovered?.status, .interrupted)
        XCTAssertEqual(recovered?.checked, 1)
        let retried = try await finished(service.start(sources: contexts))
        let recoveries = await ledger.recoveries
        XCTAssertEqual(recoveries, 2)
        XCTAssertNotEqual(retried.scanID, failed.scanID)
        XCTAssertEqual(retried.summary.status, .completed)
        XCTAssertEqual(retried.summary.checked, 1)
        XCTAssertNil(retried.error)
    }
}

#endif
