import Foundation
import XCTest
import MihonCompatKit
@testable import KamiCore

final class SourceCompatibilityDiagnosticsTests: XCTestCase {
    private struct ReportingSource: InterpretedCompatibilityReportingSource {
        let id: Int64 = 42
        let name = "Report fixture"
        let language = "en"
        let baseURL = "https://private.invalid"
        let read: @Sendable () -> InterpretedCompatibilityRuntimeReport
        func compatibilityReport() -> InterpretedCompatibilityRuntimeReport { read() }
        func getPopularManga(page: Int) async throws -> MangasPageCompat { XCTFail("Export must not execute a source"); throw CancellationError() }
        func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat { try await getPopularManga(page: page) }
        func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat { XCTFail("Export must not fetch details"); throw CancellationError() }
        func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] { XCTFail("Export must not fetch chapters"); throw CancellationError() }
        func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] { XCTFail("Export must not fetch pages"); throw CancellationError() }
    }

    private func recorder() -> InterpretedCompatibilityRecorder {
        let value = InterpretedCompatibilityRecorder(packageName: "example.extension", versionName: "1", versionCode: 1)
        value.record(stage: .pages, error: VMError.unresolvedMethod(class: "Lmissing/API;", signature: "call()V"))
        return value
    }

    private func snapshot(scope: SourceRequestScope = .init(),
                          read: @escaping @Sendable () -> InterpretedCompatibilityRuntimeReport) -> SourceRegistrationSnapshot {
        .init(source: ReportingSource(read: read), revision: 7, origin: .pinnedCompatibilityProfile, scope: scope)
    }

    func testCaptureKeepsExactRegistrationAndImmutableSnapshotWithoutSourceRequests() async throws {
        let recorder = recorder()
        let registration = snapshot { recorder.report() }
        let first = try await SourceCompatibilityDiagnostics.prepare(registration: registration)
        recorder.record(stage: .search, error: VMError.unresolvedClass("Lnew/Gap;"))
        let second = try await SourceCompatibilityDiagnostics.prepare(registration: registration)
        XCTAssertEqual(first.registrationID, registration.registrationID)
        XCTAssertEqual(first.sourceID, 42)
        XCTAssertEqual(first.revision, 7)
        XCTAssertEqual(first.export.report.findings.count, 1)
        XCTAssertEqual(second.export.report.findings.count, 2)
        XCTAssertNotEqual(first.export.data, second.export.data)
        XCTAssertFalse(String(decoding: first.export.data, as: UTF8.self).contains("private.invalid"))
    }

    @MainActor
    func testNativeAndRevokedSourcesDoNotReadOrManufactureReports() async throws {
        let native = try XCTUnwrap(SourceRegistry().registrationSnapshot(id: MangaDexSource().id))
        do { _ = try await SourceCompatibilityDiagnostics.prepare(registration: native); XCTFail("Native report manufactured") }
        catch is SourceCompatibilityDiagnosticsError {}
        let scope = SourceRequestScope()
        scope.revoke()
        let value = recorder().report()
        let revoked = snapshot(scope: scope) { XCTFail("Revoked source was read"); return value }
        do { _ = try await SourceCompatibilityDiagnostics.prepare(registration: revoked); XCTFail("Revoked report published") }
        catch is CancellationError {}
    }

    private final class BlockedReader: @unchecked Sendable {
        let entered: XCTestExpectation
        let release = DispatchSemaphore(value: 0)
        let report: InterpretedCompatibilityRuntimeReport
        init(entered: XCTestExpectation, report: InterpretedCompatibilityRuntimeReport) {
            self.entered = entered; self.report = report
        }
        func read() -> InterpretedCompatibilityRuntimeReport {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return report
        }
    }

    @MainActor
    func testCancellationDrainsSnapshotWorkerBeforeReleasingLibraryOperation() async throws {
        let entered = expectation(description: "Snapshot read started")
        let reader = BlockedReader(entered: entered, report: recorder().report())
        let registration = snapshot { reader.read() }
        let operations = LibraryOperationCoordinator()
        let presentation = operations.state.presentation
        let worker = try operations.start(expected: presentation) {
            try await SourceCompatibilityDiagnostics.prepare(registration: registration)
        }
        await fulfillment(of: [entered], timeout: 3)
        worker.cancel()
        XCTAssertEqual(operations.state.activeOperations, 1)
        XCTAssertThrowsError(try operations.beginExclusive(expected: presentation))
        reader.release.signal()
        do { _ = try await worker.value; XCTFail("Cancelled report published") }
        catch is CancellationError {}
        XCTAssertEqual(operations.state.activeOperations, 0)
        let exclusive = try operations.beginExclusive(expected: presentation)
        try operations.finishExclusive(exclusive)
    }

    func testRevocationDuringSnapshotReadRejectsLateReport() async throws {
        let entered = expectation(description: "Snapshot read started")
        let reader = BlockedReader(entered: entered, report: recorder().report())
        let scope = SourceRequestScope()
        let registration = snapshot(scope: scope) { reader.read() }
        let worker = Task { try await SourceCompatibilityDiagnostics.prepare(registration: registration) }
        await fulfillment(of: [entered], timeout: 3)
        scope.revoke()
        reader.release.signal()
        do { _ = try await worker.value; XCTFail("Replaced source report published") }
        catch is CancellationError {}
    }

    private actor GapTransport: CompatHTTPTransport {
        nonisolated let sourceID = "diagnostics-fixture"
        var calls = 0
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            calls += 1
            throw VMError.unresolvedMethod(class: "Lshared/missing/Client;", signature: "execute()V")
        }
    }

    @MainActor
    func testRealPinnedFailureExportsThroughRegisteredSnapshotAndPromotesWithoutMoreTransport() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent("Tests/corpus/batcave.apk")))
        let transport = GapTransport()
        let source = try PinnedInterpretedSource.batCave169(apkBytes: bytes, transport: transport)
        let registry = SourceRegistry()
        registry.addPinned(source)
        let registration = try XCTUnwrap(registry.registrationSnapshot(id: source.id))
        do { _ = try await registration.source.getPopularManga(page: 1); XCTFail("Injected failure expected") }
        catch is VMError {}
        let callsBefore = await transport.calls
        let prepared = try await SourceCompatibilityDiagnostics.prepare(registration: registration)
        let callsAfter = await transport.calls
        XCTAssertEqual(callsBefore, 1)
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertEqual(prepared.export.report.packageName, "eu.kanade.tachiyomi.extension.en.batcave")
        XCTAssertEqual(prepared.export.report.versionName, "1.6.9")
        let seed = try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: String(decoding: prepared.export.data, as: UTF8.self))
        XCTAssertEqual(seed.stage, .popular)
        XCTAssertEqual(seed.surface, .unresolvedMethod(classDescriptor: "Lshared/missing/Client;", signature: "execute()V"))
        XCTAssertFalse(prepared.export.report.renderedText().contains("batcave.biz"))
    }
}
