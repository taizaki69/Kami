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

    func testCaughtBridgeGapRecordsOnlyTheFirstUnsupportedSurface() throws {
        var builder = DexBuilder()
        let recover = builder.method(
            classDescriptor: "Lprobe/Bridge;",
            name: "recover",
            shorty: "I",
            ret: "I"
        )
        builder.setClass("LProbe;")
        builder.addMethod(.init(
            name: "run",
            registers: 1,
            ins: 0,
            outs: 0,
            insns: Insn.invokeStatic(recover, [])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true,
            returnType: "I"
        ))

        let bridge = HostBridge.minimal()
        bridge.register(
            class: "Lprobe/Bridge;",
            "recover",
            prototype: "()I",
            isStatic: true
        ) { vm, _ in
            do {
                _ = try vm.call(
                    classDescriptor: "LProbe;",
                    method: "firstMissing",
                    prototype: "()V"
                )
            } catch let error as VMError {
                guard case .unresolvedMethod = error else { throw error }
            }
            do {
                _ = try vm.call(
                    classDescriptor: "LProbe;",
                    method: "secondMissing",
                    prototype: "()V"
                )
            } catch let error as VMError {
                guard case .unresolvedMethod = error else { throw error }
            }
            return .int(7)
        }

        let recorder = InterpretedCompatibilityRecorder(
            packageName: "example.probe",
            versionName: "1.0",
            versionCode: 1
        )
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let result = try vm.withFirstCompatibilityGapObservation({ error in
            recorder.record(stage: .popular, error: error)
        }) {
            try vm.call(
                classDescriptor: "LProbe;",
                method: "run",
                prototype: "()I"
            )
        }

        guard case let .int(value) = result else {
            return XCTFail("expected recovered int result")
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(recorder.report().findings, [
            InterpretedCompatibilityFinding(
                stage: .popular,
                surface: .unresolvedMethod(
                    classDescriptor: "LProbe;",
                    signature: "firstMissing()V"
                ),
                occurrences: 1
            ),
        ])
    }

    func testUnknownExternalInstanceAndStaticFieldsFailClosedAndAreRecorded() throws {
        var builder = DexBuilder()
        let staticField = builder.field(
            classDescriptor: "Lprobe/ExternalState;",
            name: "count",
            typeDescriptor: "I"
        )
        let instanceField = builder.field(
            classDescriptor: "Lprobe/ExternalBox;",
            name: "value",
            typeDescriptor: "I"
        )
        builder.setClass("LProbe;")
        builder.addMethod(.init(
            name: "readStatic",
            registers: 1,
            ins: 0,
            outs: 0,
            insns: Insn.sget(0, staticField) + Insn.returnReg(0),
            isStatic: true,
            returnType: "I"
        ))
        builder.addMethod(.init(
            name: "readInstance",
            registers: 2,
            ins: 1,
            outs: 0,
            insns: Insn.iget(0, 1, instanceField) + Insn.returnReg(0),
            isStatic: true,
            returnType: "I",
            parameters: ["Lprobe/ExternalBox;"]
        ))

        let recorder = InterpretedCompatibilityRecorder(
            packageName: "example.fields",
            versionName: "1.0",
            versionCode: 1
        )
        let vm = DexInterpreter(dex: try DexFile(builder.build()))

        XCTAssertThrowsError(try vm.withFirstCompatibilityGapObservation({ error in
            recorder.record(stage: .construction, error: error)
        }) {
            try vm.call(
                classDescriptor: "LProbe;",
                method: "readStatic",
                prototype: "()I"
            )
        }) { error in
            guard case let VMError.unresolvedField(classDescriptor, name) = error else {
                return XCTFail("expected unresolved static field, got \(error)")
            }
            XCTAssertEqual(classDescriptor, "Lprobe/ExternalState;")
            XCTAssertEqual(name, "count")
        }

        let emptyBox = RVal.obj(ObjInstance(
            dexType: "Lprobe/ExternalBox;",
            isHost: true
        ))
        XCTAssertThrowsError(try vm.withFirstCompatibilityGapObservation({ error in
            recorder.record(stage: .metadata, error: error)
        }) {
            try vm.call(
                classDescriptor: "LProbe;",
                method: "readInstance",
                prototype: "(Lprobe/ExternalBox;)I",
                args: [emptyBox]
            )
        }) { error in
            guard case let VMError.unresolvedField(classDescriptor, name) = error else {
                return XCTFail("expected unresolved instance field, got \(error)")
            }
            XCTAssertEqual(classDescriptor, "Lprobe/ExternalBox;")
            XCTAssertEqual(name, "value")
        }

        let populatedBox = RVal.obj(ObjInstance(
            dexType: "Lprobe/ExternalBox;",
            fields: ["value": .int(9)],
            isHost: true
        ))
        let populatedResult = try vm.call(
            classDescriptor: "LProbe;",
            method: "readInstance",
            prototype: "(Lprobe/ExternalBox;)I",
            args: [populatedBox]
        )
        guard case let .int(populatedValue) = populatedResult else {
            return XCTFail("expected populated external field value")
        }
        XCTAssertEqual(populatedValue, 9)

        XCTAssertEqual(recorder.report().findings, [
            InterpretedCompatibilityFinding(
                stage: .construction,
                surface: .unresolvedField(
                    classDescriptor: "Lprobe/ExternalState;",
                    name: "count"
                ),
                occurrences: 1
            ),
            InterpretedCompatibilityFinding(
                stage: .metadata,
                surface: .unresolvedField(
                    classDescriptor: "Lprobe/ExternalBox;",
                    name: "value"
                ),
                occurrences: 1
            ),
        ])
    }

    func testRuntimeReportPromotesToDeterministicPrivacySafeRegressionSeed() throws {
        let recorder = InterpretedCompatibilityRecorder(
            packageName: "example.extension",
            versionName: "1.2.3",
            versionCode: 12
        )
        XCTAssertTrue(recorder.record(
            stage: .search,
            error: VMError.unresolvedMethod(
                class: "Lmissing/API;",
                signature: "call(Ljava/lang/String;)V"
            )
        ))
        let text = recorder.report().renderedText()
        let first = try InterpretedCompatibilityRegressionPromotion.seed(
            fromRenderedReport: text
        )
        let second = try InterpretedCompatibilityRegressionPromotion.seed(
            fromRenderedReport: text
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.packageName, "example.extension")
        XCTAssertEqual(first.versionName, "1.2.3")
        XCTAssertEqual(first.versionCode, 12)
        XCTAssertEqual(first.stage, .search)
        XCTAssertEqual(
            first.surface,
            .unresolvedMethod(
                classDescriptor: "Lmissing/API;",
                signature: "call(Ljava/lang/String;)V"
            )
        )
        XCTAssertEqual(first.renderedXCTestAssertion(), """
        // Promoted from a privacy-safe Kami runtime compatibility report.
        // package: example.extension
        // version: 1.2.3 (12)
        // Execute the exact deterministic search operation before this assertion.
        let fixedCompatibilitySurface: InterpretedCompatibilitySurface = .unresolvedMethod(
            classDescriptor: "Lmissing/API;",
            signature: "call(Ljava/lang/String;)V"
        )
        XCTAssertFalse(
            source.compatibilityReport().findings.contains {
                $0.stage == .search &&
                    $0.surface == fixedCompatibilitySurface
            },
            "fixed compatibility gap regressed"
        )

        """)

        let emptyReport = InterpretedCompatibilityRecorder(
            packageName: "example.extension",
            versionName: "1.2.3",
            versionCode: 12
        ).report().renderedText()
        XCTAssertThrowsError(try InterpretedCompatibilityRegressionPromotion.seed(
            fromRenderedReport: emptyReport
        )) { error in
            XCTAssertEqual(
                error as? InterpretedCompatibilityRegressionPromotionError,
                .noFinding
            )
        }

        let unsafe = text.replacingOccurrences(
            of: "Lmissing/API;->call(Ljava/lang/String;)V",
            with: "https://private.invalid/?token=secret"
        )
        XCTAssertThrowsError(try InterpretedCompatibilityRegressionPromotion.seed(
            fromRenderedReport: unsafe
        )) { error in
            XCTAssertEqual(
                error as? InterpretedCompatibilityRegressionPromotionError,
                .invalidReport
            )
        }
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
