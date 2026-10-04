import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

#if canImport(SQLite3)

final class LibraryDownloadServiceTests: XCTestCase {
    private static let nativeID = MangaDexSource().id

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
        var pageLists: [String] = []
        var images: [Int] = []
        var executions: [Int] = []
        var active = 0
        var maximumActive = 0
        func list(_ chapter: SChapterCompat) { pageLists.append(chapter.url) }
        func resolve(_ page: PageCompat) { images.append(page.index) }
        func begin(_ page: PageCompat) {
            executions.append(page.index)
            active += 1
            maximumActive = max(maximumActive, active)
        }
        func end() { active -= 1 }
    }

    private struct Source: KamiSource {
        let id = LibraryDownloadServiceTests.nativeID
        let name = "Offline fixture source"
        let language = "en"
        let baseURL = "https://fixture.invalid"
        let probe: Probe
        var pages: @Sendable (SChapterCompat) async throws -> [PageCompat] = { _ in
            [.init(index: 0, imageURL: "https://images.invalid/same.png")]
        }
        var imageAvailable = true
        var execution: @Sendable (PageCompat) async throws -> [UInt8] = { page in [UInt8(page.index + 1), 8] }
        func getPopularManga(page: Int) async throws -> MangasPageCompat { throw FixtureFailure.request }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
            throw FixtureFailure.request
        }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { throw FixtureFailure.request }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { throw FixtureFailure.request }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] {
            await probe.list(chapter)
            return try await pages(chapter)
        }
        func getImageRequest(page: PageCompat) async -> ImageRequest? {
            await probe.resolve(page)
            guard imageAvailable else { return nil }
            return ImageRequest(url: page.imageURL ?? "https://images.invalid/page.png", sourceExecutionID: UUID()) {
                await probe.begin(page)
                do {
                    let body = try await execution(page)
                    await probe.end()
                    return .init(finalURL: "https://images.invalid/page.png", statusCode: 200, body: body)
                } catch { await probe.end(); throw error }
            }
        }
    }

    private enum FixtureFailure: Error, LocalizedError {
        case request
        var errorDescription: String? { "private https://fixture.invalid/image?token=secret" }
    }

    private actor Provider {
        var value: DownloadSourceContext
        var calls = 0
        let gate: Gate?
        init(_ value: DownloadSourceContext, gate: Gate? = nil) { self.value = value; self.gate = gate }
        func get(_ sourceID: Int64) async -> DownloadSourceContext {
            calls += 1
            await gate?.wait()
            return value
        }
        func set(_ value: DownloadSourceContext) { self.value = value }
    }

    private struct Validator: DownloadImageValidating {
        var reject = false
        var cancel = false
        func validate(_ data: Data) async throws {
            if cancel { throw CancellationError() }
            if reject { throw DownloadImageValidationError.invalidImage }
            guard data.count == 2 else { throw DownloadImageValidationError.invalidImage }
        }
    }

    private struct Fixture {
        let folder: URL
        let path: String
        let store: LibraryStore
        let content: DownloadContentStore
        let chapters: [Chapter]
        let mangaID: Int64
    }

    private func fixture(
        chapterCount: Int = 2,
        policy: DownloadPolicy = .init(maximumPageBytes: 16, maximumChapterBytes: 64,
            quotaBytes: 4 * 1024 * 1024, freeSpaceFloorBytes: 0, maximumManifestBytes: 1_024),
        rejectImages: Bool = false, cancelValidation: Bool = false
    ) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Kami-Download-Service-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try LibraryStore(path: path, downloadPolicy: policy)
        let mangaID = try await store.upsert(Manga(sourceId: Self.nativeID, url: "/series", title: "Keep", inLibrary: true))
        try await store.replaceChapters(mangaId: mangaID, with: (0..<chapterCount).map {
            Chapter(mangaId: mangaID, sourceOrder: $0, url: "/chapter/\($0)", name: "Chapter \($0)",
                read: true, bookmark: true, lastPageRead: 7)
        })
        let chapters = try await store.chapters(mangaId: mangaID)
        let content = try DownloadContentStore(root: folder.appendingPathComponent("Downloads/v1"), policy: policy,
            validator: Validator(reject: rejectImages, cancel: cancelValidation))
        return Fixture(folder: folder, path: path, store: store, content: content, chapters: chapters, mangaID: mangaID)
    }

    private func provider(_ source: Source, scope: SourceRequestScope = .init()) -> Provider {
        // An offline native source fixture replaces only the test seam. It
        // does not admit an extension, create a DEX VM or execute HTTP.
        Provider(.available(registration: .init(source: source, revision: 1, origin: .native, scope: scope),
            expectedConfiguration: nil))
    }

    private func service(_ fixture: Fixture, provider: Provider) -> LibraryDownloadService {
        LibraryDownloadService(store: fixture.store, contentStore: fixture.content, sourceProvider: { await provider.get($0) })
    }

    private func queued(_ fixture: Fixture, index: Int = 0) async throws -> DownloadItem {
        try await fixture.store.enqueueDownload(chapterID: XCTUnwrap(fixture.chapters[index].id), expectedConfiguration: nil)
    }

    private func finish(_ run: DownloadRun) async -> DownloadProgress? {
        var last: DownloadProgress?
        for await update in run.updates { last = update }
        XCTAssertEqual(last?.phase, .finished)
        return last
    }

    func testQueueIsExplicitSerialAndCompleteChapterReadsWithoutSource() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let probe = Probe()
        let source = Source(probe: probe, pages: { _ in
            [.init(index: 0, imageURL: "https://images.invalid/same.png"),
             .init(index: 1, imageURL: "https://images.invalid/same.png")]
        })
        let provider = provider(source)
        let service = service(f, provider: provider)
        try await service.prepare()
        let first = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        _ = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[1].id))
        let before = await probe.pageLists
        XCTAssertTrue(before.isEmpty)
        let result = await finish(try await service.start())
        XCTAssertNil(result?.error)
        let execution = await probe.executions
        let lists = await probe.pageLists
        let maximum = await probe.maximumActive
        XCTAssertEqual(lists, ["/chapter/0", "/chapter/1"])
        XCTAssertEqual(execution, [0, 1, 0, 1])
        XCTAssertEqual(maximum, 1)
        let snapshot = try await f.store.downloadsSnapshot()
        XCTAssertEqual(snapshot.summary.finished, 2)
        XCTAssertEqual(snapshot.summary.storedBytes, 8)
        XCTAssertEqual(snapshot.items.first?.jobID, first.jobID)
        await provider.set(.unavailable)
        let calls = await provider.calls
        let lease = try await service.openOfflineChapter(chapterID: XCTUnwrap(f.chapters[0].id))
        let firstPage = try await lease.readPage(ordinal: 0)
        let secondPage = try await lease.readPage(ordinal: 1)
        XCTAssertEqual(firstPage, Data([1, 8]))
        XCTAssertEqual(secondPage, Data([2, 8]))
        await lease.close()
        let after = await provider.calls
        XCTAssertEqual(after, calls)
    }

    func testDuplicateStartAndPauseBeforeFreshContextDrainsWithoutNetwork() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let queued = try await queued(f)
        let entered = expectation(description: "provider entered")
        let gate = Gate(entered)
        let probe = Probe()
        let source = Source(probe: probe)
        let provider = Provider(.available(registration: .init(source: source, revision: 1, origin: .native,
            scope: .init()), expectedConfiguration: nil), gate: gate)
        let service = service(f, provider: provider)
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await service.start(); XCTFail("Duplicate Start") }
        catch { XCTAssertEqual(error as? LibraryDownloadServiceError, .alreadyRunning) }
        let pause = Task { try await service.pause() }
        // Durable pause can be observed before this noncooperative provider
        // returns. The run remains owned until it has drained.
        for _ in 0..<100 {
            if try await f.store.downloadItem(jobID: queued.jobID)?.state == .paused { break }
            await Task.yield()
        }
        let paused = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(paused?.state, .paused)
        await gate.release()
        try await pause.value
        _ = await finish(run)
        let lists = await probe.pageLists
        XCTAssertTrue(lists.isEmpty)
        XCTAssertNil(paused?.contentIdentity)
    }

    func testCancelInvalidatesBeforeImageCancellationAndRejectsLateBytes() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "image entered")
        let cancelled = expectation(description: "image cancellation")
        let gate = Gate(entered)
        let probe = Probe()
        let provider = provider(Source(probe: probe, execution: { _ in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.fulfill() }
            return [1, 8]
        }))
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        let cancel = Task { try await service.cancel(jobID: queued.jobID) }
        await fulfillment(of: [cancelled], timeout: 2)
        let durable = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(durable?.state, .cancelled)
        XCTAssertEqual(durable?.completedPages, 0)
        do { _ = try await service.start(); XCTFail("Start must wait for cancelled transfer drain") }
        catch { XCTAssertEqual(error as? LibraryDownloadServiceError, .alreadyRunning) }
        await gate.release()
        let returned = try await cancel.value
        let result = await finish(run)
        XCTAssertNil(result?.error)
        XCTAssertEqual(returned?.state, .cancelled)
        XCTAssertNil(returned?.contentIdentity)
        let offline = try await f.store.offlineChapter(chapterID: XCTUnwrap(f.chapters[0].id))
        let usage = try await f.content.usage()
        XCTAssertNil(offline)
        XCTAssertEqual(usage.totalBytes, 0)
        XCTAssertEqual(usage.reservedBytes, 0)
    }

    func testPauseLeavesOtherQueuedAndRetryStartsFreshPageZero() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "first page")
        let cancelled = expectation(description: "pause cancellation")
        let gate = Gate(entered)
        let probe = Probe()
        let provider = provider(Source(probe: probe, execution: { _ in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.fulfill() }
            return [1, 8]
        }))
        let service = service(f, provider: provider)
        let first = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let other = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[1].id))
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        let old = try await f.store.downloadItem(jobID: first.jobID)
        let pause = Task { try await service.pause() }
        await fulfillment(of: [cancelled], timeout: 2)
        await gate.release()
        try await pause.value
        _ = await finish(run)
        let untouched = try await f.store.downloadItem(jobID: other.jobID)
        XCTAssertEqual(untouched?.state, .queued)
        let retried = try await service.retry(jobID: first.jobID)
        XCTAssertEqual(retried.state, .queued)
        XCTAssertNil(retried.attemptID)
        _ = await finish(try await service.start())
        let completed = try await f.store.downloadItem(jobID: first.jobID)
        let execution = await probe.executions
        let lists = await probe.pageLists
        XCTAssertEqual(completed?.state, .finished)
        XCTAssertNotEqual(completed?.attemptID, old?.attemptID)
        XCTAssertEqual(execution, [0, 0, 0])
        XCTAssertEqual(lists, ["/chapter/0", "/chapter/1", "/chapter/0"])
    }

    func testRequestFailureIsFiniteAndDoesNotStopAnotherChapter() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let probe = Probe()
        let provider = provider(Source(probe: probe, pages: { chapter in
            if chapter.url == "/chapter/0" { throw FixtureFailure.request }
            return [.init(index: 0, imageURL: "https://images.invalid/page.png")]
        }))
        let service = service(f, provider: provider)
        let first = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        _ = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[1].id))
        let result = await finish(try await service.start())
        let failed = try await f.store.downloadItem(jobID: first.jobID)
        let snapshot = try await f.store.downloadsSnapshot()
        XCTAssertEqual(failed?.reason, .transferFailed)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(snapshot.summary.finished, 1)
        XCTAssertNil(result?.error)
        XCTAssertFalse(String(describing: result).contains("token=secret"))
    }

    func testMissingSourceAndConfigurationFailBeforePageResolution() async throws {
        for context in [DownloadSourceContext.unavailable, .configurationUnavailable] {
            let f = try await fixture(chapterCount: 1)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            let queued = try await queued(f)
            let provider = Provider(context)
            let service = service(f, provider: provider)
            let result = await finish(try await service.start())
            let failed = try await f.store.downloadItem(jobID: queued.jobID)
            XCTAssertEqual(failed?.state, .failed)
            XCTAssertEqual(failed?.reason, context.isUnavailable ? .sourceUnavailable : .configurationChanged)
            XCTAssertNil(failed?.contentIdentity)
            XCTAssertNil(result?.error)
        }
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let queued = try await queued(f)
        let probe = Probe()
        let wrong = SourceRegistrationSnapshot(source: Source(probe: probe), revision: 1,
            origin: .downloadedExtension(packageName: "fixture.extension"), scope: .init())
        let service = service(f, provider: Provider(.available(registration: wrong, expectedConfiguration: nil)))
        _ = await finish(try await service.start())
        let failed = try await f.store.downloadItem(jobID: queued.jobID)
        let lists = await probe.pageLists
        XCTAssertEqual(failed?.reason, .configurationChanged)
        XCTAssertTrue(lists.isEmpty)
    }

    func testRevokedRegistrationDiscardsLatePageListWithoutImages() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "page list")
        let gate = Gate(entered)
        let probe = Probe()
        let scope = SourceRequestScope()
        let provider = provider(Source(probe: probe, pages: { _ in
            await gate.wait()
            return [.init(index: 0, imageURL: "https://images.invalid/page.png")]
        }), scope: scope)
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        scope.revoke()
        await gate.release()
        _ = await finish(run)
        let failed = try await f.store.downloadItem(jobID: queued.jobID)
        let resolved = await probe.images
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.reason, .configurationChanged)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertNil(failed?.contentIdentity)
    }

    func testPageListLimitsRejectBeforeImageResolution() async throws {
        let invalid: [[PageCompat]] = [
            [], [.init(index: 1, imageURL: "https://images.invalid/page.png")],
            [.init(index: 0, imageURL: String(repeating: "a", count: 4_097))],
            (0..<2_049).map { .init(index: $0, imageURL: "https://images.invalid/page.png") },
            (0..<2_048).map { .init(index: $0, url: String(repeating: "a", count: 4_096),
                imageURL: String(repeating: "b", count: 4_096)) },
        ]
        for pages in invalid {
            let f = try await fixture(chapterCount: 1)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            let probe = Probe()
            let service = service(f, provider: provider(Source(probe: probe, pages: { _ in pages })))
            let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
            _ = await finish(try await service.start())
            let failed = try await f.store.downloadItem(jobID: queued.jobID)
            let resolved = await probe.images
            XCTAssertEqual(failed?.reason, .pageListInvalid)
            XCTAssertTrue(resolved.isEmpty)
        }
    }

    func testMissingImageAndInvalidImageNeverBecomeOffline() async throws {
        for reject in [false, true] {
            let f = try await fixture(chapterCount: 1, rejectImages: reject)
            defer { try? FileManager.default.removeItem(at: f.folder) }
            let probe = Probe()
            let source = Source(probe: probe, imageAvailable: reject)
            let service = service(f, provider: provider(source))
            let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
            _ = await finish(try await service.start())
            let failed = try await f.store.downloadItem(jobID: queued.jobID)
            let offline = try await f.store.offlineChapter(chapterID: XCTUnwrap(f.chapters[0].id))
            XCTAssertEqual(failed?.reason, reject ? .imageInvalid : .imageRequestUnavailable)
            XCTAssertNil(offline)
            XCTAssertEqual(failed?.storedBytes, 0)
        }
    }

    func testQuotaIsReservedBeforeImageExecution() async throws {
        let policy = DownloadPolicy(maximumPageBytes: 16, maximumChapterBytes: 64,
            quotaBytes: 1_024, freeSpaceFloorBytes: 0, maximumManifestBytes: 1_024)
        let f = try await fixture(chapterCount: 1, policy: policy)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let probe = Probe()
        let service = service(f, provider: provider(Source(probe: probe)))
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        _ = await finish(try await service.start())
        let failed = try await f.store.downloadItem(jobID: queued.jobID)
        let resolved = await probe.images
        let executed = await probe.executions
        XCTAssertEqual(failed?.reason, .quotaExceeded)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertTrue(executed.isEmpty)
    }

    func testSQLiteCommitFailureIsStorageFailureAndStopsQueuedTransfer() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let database = try SQLiteDatabase(path: f.path)
        try database.execute("CREATE TRIGGER fixture_fail_page BEFORE INSERT ON download_page BEGIN SELECT RAISE(ABORT,'private fixture'); END")
        let probe = Probe()
        let service = service(f, provider: provider(Source(probe: probe)))
        let first = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let second = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[1].id))
        let result = await finish(try await service.start())
        let failed = try await f.store.downloadItem(jobID: first.jobID)
        let untouched = try await f.store.downloadItem(jobID: second.jobID)
        let lists = await probe.pageLists
        XCTAssertEqual(result?.error, .storageUnavailable)
        XCTAssertEqual(failed?.reason, .storageUnavailable)
        XCTAssertEqual(untouched?.state, .queued)
        XCTAssertEqual(lists, ["/chapter/0"])
        try database.execute("DROP TRIGGER fixture_fail_page")
        _ = try await service.retry(jobID: first.jobID)
        let restarted = await finish(try await service.start())
        XCTAssertNil(restarted?.error)
        let snapshot = try await f.store.downloadsSnapshot()
        XCTAssertEqual(snapshot.summary.finished, 2)
    }

    func testRecoveryDoesNotPromoteRenamedPreparedBundleOrUseSource() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let queued = try await queued(f)
        let attempt = try await f.store.beginDownloadAttempt(jobID: queued.jobID, expectedConfiguration: nil)
        try await f.content.begin(identity: attempt.identity)
        _ = try await f.store.setDownloadPageCount(attempt: attempt, pageCount: 1)
        try await f.content.reservePage(identity: attempt.identity)
        let page = try await f.content.writePage(identity: attempt.identity, ordinal: 0, data: Data([1, 8]))
        _ = try await f.store.commitDownloadPage(attempt: attempt, receipt: page)
        let manifest = try await f.content.prepare(identity: attempt.identity)
        _ = try await f.store.prepareDownload(attempt: attempt, manifestReceipt: manifest)
        try await f.content.publish(receipt: manifest)
        let provider = Provider(.unavailable)
        let service = service(f, provider: provider)
        try await service.prepare()
        try await service.prepare()
        let recovered = try await f.store.downloadItem(jobID: queued.jobID)
        let calls = await provider.calls
        let usage = try await f.content.usage()
        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(recovered?.reason, .interrupted)
        XCTAssertNil(recovered?.contentIdentity)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(usage.totalBytes, 0)
        do { _ = try await service.openOfflineChapter(chapterID: XCTUnwrap(f.chapters[0].id)); XCTFail("Uncommitted bundle") }
        catch { XCTAssertEqual(error as? LibraryDownloadServiceError, .localChapterUnavailable) }
    }

    func testFailedTerminalWriteCanRecoverLocallyBeforeFreshRetry() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let database = try SQLiteDatabase(path: f.path)
        try database.execute("CREATE TRIGGER fixture_fail_page BEFORE INSERT ON download_page BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try database.execute("CREATE TRIGGER fixture_fail_terminal BEFORE UPDATE OF state ON download_job WHEN NEW.state=3 BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let provider = provider(Source(probe: Probe()))
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let failed = await finish(try await service.start())
        XCTAssertEqual(failed?.error, .storageUnavailable)
        let unfinished = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(unfinished?.state, .downloading)
        try database.execute("DROP TRIGGER fixture_fail_page")
        try database.execute("DROP TRIGGER fixture_fail_terminal")
        let calls = await provider.calls
        try await service.prepare()
        let recovered = try await f.store.downloadItem(jobID: queued.jobID)
        let after = await provider.calls
        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(recovered?.reason, .interrupted)
        XCTAssertNil(recovered?.contentIdentity)
        XCTAssertEqual(after, calls)
        _ = try await service.retry(jobID: queued.jobID)
        let final = await finish(try await service.start())
        let complete = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertNil(final?.error)
        XCTAssertEqual(complete?.state, .finished)
        XCTAssertNotEqual(complete?.attemptID, unfinished?.attemptID)
    }

    func testDeleteWaitsForLocalLeaseAndPreservesLibraryProgress() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let provider = provider(Source(probe: Probe()))
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        _ = await finish(try await service.start())
        await provider.set(.unavailable)
        let lease = try await service.openOfflineChapter(chapterID: XCTUnwrap(f.chapters[0].id))
        let deleting = try await service.delete(jobID: queued.jobID)
        XCTAssertEqual(deleting?.state, .deleting)
        XCTAssertEqual(deleting?.storedBytes, 2)
        let stillReadable = try await lease.readPage(ordinal: 0)
        XCTAssertEqual(stillReadable, Data([1, 8]))
        do { _ = try await service.openOfflineChapter(chapterID: XCTUnwrap(f.chapters[0].id)); XCTFail("Deletion blocks new leases") }
        catch { XCTAssertEqual(error as? LibraryDownloadServiceError, .localChapterUnavailable) }
        await lease.close()
        try await service.prepare()
        let gone = try await f.store.downloadItem(jobID: queued.jobID)
        let target = try await f.store.downloadTarget(chapterID: XCTUnwrap(f.chapters[0].id))
        XCTAssertNil(gone)
        XCTAssertTrue(target.manga.inLibrary)
        XCTAssertTrue(target.chapter.read)
        XCTAssertTrue(target.chapter.bookmark)
        XCTAssertEqual(target.chapter.lastPageRead, 7)
    }

    func testInvalidatingUnrelatedSourceDoesNotCancelNativeAttempt() async throws {
        let f = try await fixture(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "native transfer")
        let gate = Gate(entered)
        let provider = provider(Source(probe: Probe(), execution: { _ in await gate.wait(); return [1, 8] }))
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        try await service.invalidateSources(sourceIDs: [99])
        let active = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(active?.state, .downloading)
        await gate.release()
        _ = await finish(run)
        let complete = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(complete?.state, .finished)
    }

    func testSpontaneousDependencyCancellationTerminalizesAttemptAndAllowsNextStart() async throws {
        let f = try await fixture(chapterCount: 1, cancelValidation: true)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let provider = provider(Source(probe: Probe()))
        let service = service(f, provider: provider)
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let first = await finish(try await service.start())
        XCTAssertNil(first?.error)
        let failed = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.reason, .interrupted)
        XCTAssertNil(failed?.contentIdentity)
        let snapshot = try await f.store.downloadsSnapshot()
        XCTAssertEqual(snapshot.summary.active, 0)
        let next = await finish(try await service.start())
        XCTAssertNil(next?.error)
        let usage = try await f.content.usage()
        XCTAssertEqual(usage.totalBytes, 0)
        XCTAssertEqual(usage.reservedBytes, 0)
    }

    func testAffectedSourceInvalidationIsDurableBeforeDrainAndNeverRestartsQueuedRows() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let entered = expectation(description: "affected transfer")
        let cancelled = expectation(description: "affected cancellation")
        let gate = Gate(entered)
        let probe = Probe()
        let provider = provider(Source(probe: probe, execution: { _ in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.fulfill() }
            return [1, 8]
        }))
        let service = service(f, provider: provider)
        let active = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[0].id))
        let queued = try await service.enqueue(chapterID: XCTUnwrap(f.chapters[1].id))
        let run = try await service.start()
        await fulfillment(of: [entered], timeout: 2)
        let invalidation = Task { try await service.invalidateSources(sourceIDs: [Self.nativeID]) }
        await fulfillment(of: [cancelled], timeout: 2)
        let durable = try await f.store.downloadItem(jobID: active.jobID)
        let other = try await f.store.downloadItem(jobID: queued.jobID)
        XCTAssertEqual(durable?.state, .paused)
        XCTAssertEqual(durable?.reason, .configurationChanged)
        XCTAssertEqual(other?.state, .paused)
        await gate.release()
        try await invalidation.value
        _ = await finish(run)
        // The provider remains available in this fixture; neither availability
        // nor Start may implicitly requeue a source-invalidated attempt.
        _ = await finish(try await service.start())
        let execution = await probe.executions
        let lists = await probe.pageLists
        let snapshot = try await f.store.downloadsSnapshot()
        XCTAssertEqual(execution, [0])
        XCTAssertEqual(lists, ["/chapter/0"])
        XCTAssertEqual(snapshot.summary.paused, 2)
        XCTAssertEqual(snapshot.summary.storedBytes, 0)
    }
}

private extension DownloadSourceContext {
    var isUnavailable: Bool { if case .unavailable = self { return true }; return false }
}

#endif
