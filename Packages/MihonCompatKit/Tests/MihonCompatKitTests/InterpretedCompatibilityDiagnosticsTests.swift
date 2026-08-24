import Foundation
import XCTest
@testable import MihonCompatKit

final class InterpretedCompatibilityDiagnosticsTests: XCTestCase {
    private struct SecretError: Error, CustomStringConvertible {
        var description: String {
            "https://reader.invalid/chapter?token=secret Authorization: bearer-secret"
        }
    }

    private struct GapTransport: CompatHTTPTransport {
        let sourceID = "compatibility-gap-test"

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            throw VMError.unresolvedMethod(
                class: "Lshared/missing/Client;",
                signature: "execute(Ljava/lang/Object;)Ljava/lang/Object;"
            )
        }
    }

    func testRecorderDeduplicatesTypedSurfacesAndNeverSerializesArbitraryErrors() {
        let recorder = InterpretedCompatibilityRecorder(
            packageName: "https://private.invalid/?token=secret",
            versionName: "1.0 secret",
            versionCode: 7,
            maximumUniqueFindings: 2
        )
        XCTAssertTrue(recorder.record(
            stage: .search,
            error: VMError.unresolvedMethod(
                class: "Lmissing/API;",
                signature: "call(Ljava/lang/String;)V"
            )
        ))
        XCTAssertTrue(recorder.record(
            stage: .search,
            error: VMError.unresolvedMethod(
                class: "Lmissing/API;",
                signature: "call(Ljava/lang/String;)V"
            )
        ))
        XCTAssertTrue(recorder.record(
            stage: .pages,
            error: VMError.unsupportedOpcode(0xfe)
        ))
        XCTAssertFalse(recorder.record(stage: .popular, error: SecretError()))
        XCTAssertFalse(recorder.record(
            stage: .popular,
            error: VMError.verify("https://private.invalid/?token=secret")
        ))
        XCTAssertTrue(recorder.record(
            stage: .metadata,
            error: VMError.unresolvedClass("Lthird/unique/Class;")
        ))

        let report = recorder.report()
        XCTAssertEqual(report.packageName, "<redacted-package>")
        XCTAssertEqual(report.versionName, "<redacted-version>")
        XCTAssertEqual(report.versionCode, 7)
        XCTAssertEqual(report.droppedFindingCount, 1)
        XCTAssertEqual(report.findings.count, 2)
        XCTAssertEqual(
            report.findings.first { $0.stage == .search }?.occurrences,
            2
        )
        XCTAssertEqual(
            report.findings.first { $0.stage == .pages }?.surface,
            .unsupportedOpcode(0xfe)
        )
        let text = report.renderedText()
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("private.invalid"))
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains("bearer-secret"))
    }

    func testUnsafeDEXSymbolsAreReplacedRatherThanExported() {
        let recorder = InterpretedCompatibilityRecorder(
            packageName: "example.safe",
            versionName: "1.0",
            versionCode: 1
        )
        XCTAssertTrue(recorder.record(
            stage: .search,
            error: VMError.unresolvedMethod(
                class: "Lsecret:https://private.invalid/?token=value;",
                signature: "call()V"
            )
        ))
        let text = recorder.report().renderedText()
        XCTAssertTrue(text.contains("<redacted-symbol>->call()V"))
        XCTAssertFalse(text.contains("private.invalid"))
        XCTAssertFalse(text.contains("value"))
    }

    func testFailedPinnedOperationProducesActionableStageReport() async throws {
        let source = try PinnedInterpretedSource.batCave169(
            apkBytes: corpusAPK("batcave"),
            transport: GapTransport()
        )
        do {
            _ = try await source.getPopularManga(page: 1)
            XCTFail("expected the injected compatibility gap")
        } catch let error as VMError {
            guard case .unresolvedMethod = error else {
                return XCTFail("expected unresolved method, got \(error)")
            }
        }

        let report = source.compatibilityReport()
        XCTAssertEqual(report.packageName, "eu.kanade.tachiyomi.extension.en.batcave")
        XCTAssertEqual(report.versionName, "1.6.9")
        XCTAssertEqual(report.findings, [
            InterpretedCompatibilityFinding(
                stage: .popular,
                surface: .unresolvedMethod(
                    classDescriptor: "Lshared/missing/Client;",
                    signature: "execute(Ljava/lang/Object;)Ljava/lang/Object;"
                ),
                occurrences: 1
            ),
        ])
        XCTAssertFalse(report.renderedText().contains("https://batcave.biz"))
    }

    func testStaticCorpusAuditAndAggregationAreDeterministicAndRedacted() throws {
        let auditor = InterpretedCompatibilityAudit()
        var reports: [InterpretedCompatibilityStaticReport] = []
        for fixture in ["batcave", "kawiimanga", "mangamelon"] {
            let bytes = try corpusAPK(fixture)
            let first = try auditor.analyze(apkBytes: bytes)
            let second = try auditor.analyze(apkBytes: bytes)
            XCTAssertEqual(first, second, fixture)
            XCTAssertTrue(first.planStatus.isStructuralCandidate, fixture)
            XCTAssertEqual(first.planStatus.blockers, [], fixture)
            XCTAssertEqual(first.dexCount, 1, fixture)
            XCTAssertGreaterThan(first.codeMethodCount, 0, fixture)
            XCTAssertGreaterThan(first.instructionCount, 0, fixture)
            XCTAssertEqual(first.omittedExternalInvocationCount, 0, fixture)
            for finding in first.unregisteredExternalInvocations {
                XCTAssertFalse(finding.surface.summary.contains("://"), fixture)
                XCTAssertFalse(finding.surface.summary.contains("?"), fixture)
                XCTAssertFalse(finding.surface.summary.contains("\n"), fixture)
            }
            reports.append(first)
        }

        let aggregate = InterpretedCompatibilityAudit.aggregate(reports)
        XCTAssertEqual(
            aggregate,
            InterpretedCompatibilityAudit.aggregate(Array(reports.reversed()))
        )
        XCTAssertEqual(aggregate.extensionCount, 3)
        XCTAssertEqual(aggregate.structuralCandidateCount, 3)
        XCTAssertEqual(aggregate.planBlockers, [])
        XCTAssertEqual(aggregate.omittedExternalInvocationCount, 0)
        XCTAssertFalse(aggregate.unregisteredExternalInvocations.isEmpty)
        XCTAssertTrue(aggregate.unregisteredExternalInvocations.allSatisfy {
            (1...3).contains($0.extensionCount) && $0.invocationCount > 0
        })
    }

    private func corpusAPK(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }
}
