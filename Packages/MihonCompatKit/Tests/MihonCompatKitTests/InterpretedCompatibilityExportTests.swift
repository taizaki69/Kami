import Foundation
import XCTest
@testable import MihonCompatKit

final class InterpretedCompatibilityExportTests: XCTestCase {
    private func report(_ findings: [InterpretedCompatibilityFinding], dropped: Int = 0) -> InterpretedCompatibilityRuntimeReport {
        .init(packageName: "example.extension", versionName: "1.2.3", versionCode: 123,
              findings: findings, droppedFindingCount: dropped)
    }

    private func method(_ name: String, count: Int = 1) -> InterpretedCompatibilityFinding {
        .init(stage: .search, surface: .unresolvedMethod(classDescriptor: "Lmissing/API;", signature: "\(name)()V"), occurrences: count)
    }

    func testRecorderRejectsPathShapedSymbolsAndMalformedDescriptors() throws {
        let recorder = InterpretedCompatibilityRecorder(packageName: "example.extension", versionName: "1", versionCode: 1)
        for path in ["/private/reader/library", "Users/alice/secret", "C:/Users/alice", "file:///private/library"] {
            recorder.record(stage: .pages, error: VMError.unresolvedClass(path))
            recorder.record(stage: .search, error: VMError.unresolvedMethod(class: path, signature: "call(/private/secret)V"))
            recorder.record(stage: .metadata, error: VMError.unresolvedField(class: "Lvalid/Owner;", name: path))
        }
        let text = String(decoding: try InterpretedCompatibilityExport.prepare(recorder.report()).data, as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("<redacted-symbol>"))
        XCTAssertEqual(recorder.report().findings.count, 3)
        XCTAssertTrue(recorder.report().findings.allSatisfy { $0.occurrences == 4 })
        _ = try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: text)
    }

    func testConservativeDEXGrammarPreservesExactSupportedSymbols() {
        for value in ["Ljava/lang/String;", "[[Ljava/util/Map$Entry;", "[I", "Z", "Lx/Foo-Bar_1;"] {
            XCTAssertEqual(InterpretedCompatibilityRedaction.safeType(value), value)
        }
        for value in ["Ljava/lang/String", "L/secret;", "Lsecret//Token;", "[V", "V", "Ljava.lang.String;",
                      String(repeating: "[", count: 256) + "I", "Lé/Type;"] {
            XCTAssertEqual(InterpretedCompatibilityRedaction.safeType(value), "<redacted-symbol>")
        }
        for value in ["<init>([Ljava/lang/String;)V", "<clinit>()V", "call$default(IJZ)[[Ljava/lang/Object;", "get-impl()I"] {
            XCTAssertEqual(InterpretedCompatibilityRedaction.safeMethod(value), value)
        }
        for value in ["secret/path()V", "call(V)V", "call()", "call()Vextra", "call([V)V", "call()L/secret;", "()V"] {
            XCTAssertEqual(InterpretedCompatibilityRedaction.safeMethod(value), "<redacted-symbol>")
        }
        XCTAssertEqual(InterpretedCompatibilityRedaction.safeMember("INSTANCE$delegate"), "INSTANCE$delegate")
        XCTAssertEqual(InterpretedCompatibilityRedaction.safeMember("/private/name"), "<redacted-symbol>")
    }

    func testExportRevalidatesForgedReportsAndPromotionRejectsOldPathShapedText() throws {
        let input = InterpretedCompatibilityRuntimeReport(packageName: "https://private.invalid?secret=value",
            versionName: "secret\nAuthorization: bearer-token", versionCode: 1, findings: [
                .init(stage: .pages, surface: .unresolvedClass("/private/library"), occurrences: 1),
                .init(stage: .search, surface: .unresolvedMethod(classDescriptor: "Lvalid/Owner;", signature: "/private()V"), occurrences: 1)
            ], droppedFindingCount: 0)
        let exported = try InterpretedCompatibilityExport.prepare(input)
        let text = String(decoding: exported.data, as: UTF8.self)
        XCTAssertEqual(exported.report.packageName, "<redacted-package>")
        XCTAssertEqual(exported.report.versionName, "<redacted-version>")
        for secret in ["private", "secret", "Authorization", "bearer", "library"] { XCTAssertFalse(text.contains(secret)) }
        _ = try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: text)
        let forged = report([.init(stage: .pages, surface: .unresolvedClass("/private/library"), occurrences: 1)]).renderedText()
        XCTAssertThrowsError(try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: forged))
    }

    func testDeterministicOrderingDeduplicationAndCanonicalRoundTrip() throws {
        let findings = [method("z", count: 2), method("a", count: 3), method("a", count: 4)]
        let first = try InterpretedCompatibilityExport.prepare(report(findings))
        let second = try InterpretedCompatibilityExport.prepare(report(findings.reversed()))
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.capturedFindingCount, 2)
        XCTAssertEqual(first.report.findings.map(\.occurrences), [7, 2])
        XCTAssertEqual(first.data, Data(first.report.renderedText().utf8))
        XCTAssertEqual(first.omittedFindingCount, 0)
        let seed = try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: String(decoding: first.data, as: UTF8.self))
        XCTAssertEqual(seed.surface, method("a").surface)
    }

    func testFindingAndByteLimitsPreserveWholeLinesAndExplainOmissions() throws {
        let limited = try InterpretedCompatibilityExport.prepare(report([method("c", count: 9), method("a"), method("b")], dropped: 7), maximumFindings: 2)
        XCTAssertEqual(limited.report.findings.map(\.surface), [method("a").surface, method("b").surface])
        XCTAssertEqual(limited.omittedFindingCount, 1)
        XCTAssertEqual(limited.exportOmittedOccurrences, 9)
        XCTAssertEqual(limited.recorderDroppedOccurrences, 7)
        XCTAssertEqual(limited.report.droppedFindingCount, 16)

        let owner = "L" + String(repeating: "X", count: 4_094) + ";"
        let large = (0..<3).map { index in
            InterpretedCompatibilityFinding(stage: .search, surface: .unresolvedMethod(classDescriptor: owner,
                signature: "m\(index)" + String(repeating: "x", count: 4_090) + "()V"), occurrences: 1)
        }
        let bounded = try InterpretedCompatibilityExport.prepare(report(large), maximumBytes: 16_384)
        XCTAssertEqual(bounded.report.findings.count, 1)
        XCTAssertEqual(bounded.omittedFindingCount, 2)
        XCTAssertLessThanOrEqual(bounded.data.count, 16_384)
        let text = String(decoding: bounded.data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("dropped: 2\n"))
        _ = try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: text)

        let many = try InterpretedCompatibilityExport.prepare(report((0..<600).map { method(String(format: "call%04d", $0)) }))
        XCTAssertEqual(many.report.findings.count, 512)
        XCTAssertEqual(many.omittedFindingCount, 88)
        XCTAssertLessThanOrEqual(many.data.count, InterpretedCompatibilityExport.maximumBytes)
    }

    func testCountsSaturateAndEmptyReportIsHonestCanonicalData() throws {
        let exported = try InterpretedCompatibilityExport.prepare(report([
            method("a", count: Int.max), method("a", count: 1), method("b", count: Int.max), method("c", count: 1)
        ], dropped: 2), maximumFindings: 1)
        XCTAssertEqual(exported.report.findings.first?.occurrences, Int.max)
        XCTAssertEqual(exported.exportOmittedOccurrences, Int.max)
        XCTAssertEqual(exported.report.droppedFindingCount, Int.max)
        let empty = try InterpretedCompatibilityExport.prepare(report([]))
        XCTAssertFalse(empty.report.hasFindings)
        XCTAssertEqual(empty.data, Data("Kami compatibility report v1\npackage: example.extension\nversion: 1.2.3 (123)\nfindings: 0\n".utf8))
        XCTAssertThrowsError(try InterpretedCompatibilityRegressionPromotion.seed(fromRenderedReport: empty.report.renderedText())) {
            XCTAssertEqual($0 as? InterpretedCompatibilityRegressionPromotionError, .noFinding)
        }
    }

    func testInvalidLimitsInvalidCountsAndCancellationDoNotProduceBytes() async throws {
        for count in [0, 513, Int.max] {
            XCTAssertThrowsError(try InterpretedCompatibilityExport.prepare(report([]), maximumFindings: count))
        }
        for size in [-1, 16_383, InterpretedCompatibilityExport.maximumBytes + 1] {
            XCTAssertThrowsError(try InterpretedCompatibilityExport.prepare(report([]), maximumBytes: size))
        }
        for input in [report([method("a", count: 0)]), report([], dropped: -1), report(Array(repeating: method("a"), count: 4_097))] {
            XCTAssertThrowsError(try InterpretedCompatibilityExport.prepare(input))
        }
        let input = report([method("a")])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try InterpretedCompatibilityExport.prepare(input)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled export produced bytes") }
        catch is CancellationError {}
    }
}
