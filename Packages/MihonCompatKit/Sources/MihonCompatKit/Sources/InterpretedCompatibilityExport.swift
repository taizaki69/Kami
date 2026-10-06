import Foundation

public enum InterpretedCompatibilityExportError: Error, Equatable, Sendable, LocalizedError {
    case invalidLimits, invalidReport

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The report size limit is unavailable."
        case .invalidReport: "The compatibility report could not be prepared safely."
        }
    }
}

/// One immutable canonical v1 report. The report and bytes describe the same
/// bounded subset; omission counters remain separate for the app's review.
public struct InterpretedCompatibilityExport: Sendable {
    public let report: InterpretedCompatibilityRuntimeReport
    public let data: Data
    public let capturedFindingCount: Int
    public let omittedFindingCount: Int
    public let recorderDroppedOccurrences: Int
    public let exportOmittedOccurrences: Int

    public static let maximumBytes = 4 * 1_024 * 1_024
    public static let maximumFindings = 512

    private struct Key: Hashable {
        let stage: InterpretedCompatibilityStage
        let surface: InterpretedCompatibilitySurface
    }

    /// Revalidates output even if a future report producer bypasses the
    /// recorder. It never accepts error descriptions or source request values.
    public static func prepare(
        _ input: InterpretedCompatibilityRuntimeReport,
        maximumFindings: Int = Self.maximumFindings,
        maximumBytes: Int = Self.maximumBytes
    ) throws -> Self {
        try Task.checkCancellation()
        guard (1...Self.maximumFindings).contains(maximumFindings),
              (16_384...Self.maximumBytes).contains(maximumBytes) else {
            throw InterpretedCompatibilityExportError.invalidLimits
        }
        guard input.findings.count <= 4_096, input.versionCode >= 0,
              input.droppedFindingCount >= 0 else { throw InterpretedCompatibilityExportError.invalidReport }
        let package = InterpretedCompatibilityRedaction.safePackage(input.packageName)
        let version = InterpretedCompatibilityRedaction.safeVersion(input.versionName)
        var occurrences: [Key: Int] = [:]
        for finding in input.findings {
            try Task.checkCancellation()
            guard finding.occurrences > 0 else { throw InterpretedCompatibilityExportError.invalidReport }
            let surface: InterpretedCompatibilitySurface
            switch finding.surface {
            case let .unresolvedClass(value):
                surface = .unresolvedClass(InterpretedCompatibilityRedaction.safeType(value))
            case let .unresolvedMethod(owner, signature):
                surface = .unresolvedMethod(classDescriptor: InterpretedCompatibilityRedaction.safeType(owner),
                    signature: InterpretedCompatibilityRedaction.safeMethod(signature))
            case let .unresolvedField(owner, name):
                surface = .unresolvedField(classDescriptor: InterpretedCompatibilityRedaction.safeType(owner),
                    name: InterpretedCompatibilityRedaction.safeMember(name))
            case .unsupportedOpcode: surface = finding.surface
            }
            let key = Key(stage: finding.stage, surface: surface)
            occurrences[key] = adding(occurrences[key, default: 0], finding.occurrences)
        }
        let findings = occurrences.map {
            InterpretedCompatibilityFinding(stage: $0.key.stage, surface: $0.key.surface, occurrences: $0.value)
        }.sorted {
            if $0.stage != $1.stage { return $0.stage.rawValue < $1.stage.rawValue }
            if $0.surface.kind != $1.surface.kind { return $0.surface.kind < $1.surface.kind }
            return $0.surface.summary < $1.surface.summary
        }
        // Reserve enough for the largest header count and dropped footer.
        // The final renderer uses actual counts; no partial lines are emitted.
        let envelope = "Kami compatibility report v1\npackage: \(package)\nversion: \(version) (\(input.versionCode))\n"
            + "findings: \(maximumFindings)\ndropped: \(Int.max)\n"
        var bytes = envelope.utf8.count
        var retained: [InterpretedCompatibilityFinding] = []
        var omittedOccurrences = 0
        var full = false
        for finding in findings {
            try Task.checkCancellation()
            let line = "\(finding.stage.rawValue) | \(finding.surface.kind) | \(finding.surface.summary) | count=\(finding.occurrences)\n"
            if full || retained.count == maximumFindings || bytes + line.utf8.count > maximumBytes {
                full = true
                omittedOccurrences = adding(omittedOccurrences, finding.occurrences)
            } else {
                retained.append(finding)
                bytes += line.utf8.count
            }
        }
        let report = InterpretedCompatibilityRuntimeReport(packageName: package, versionName: version,
            versionCode: input.versionCode, findings: retained,
            droppedFindingCount: adding(input.droppedFindingCount, omittedOccurrences))
        let data = Data(report.renderedText().utf8)
        guard data.count <= maximumBytes else { throw InterpretedCompatibilityExportError.invalidReport }
        try Task.checkCancellation()
        return Self(report: report, data: data, capturedFindingCount: findings.count,
            omittedFindingCount: findings.count - retained.count,
            recorderDroppedOccurrences: input.droppedFindingCount, exportOmittedOccurrences: omittedOccurrences)
    }

    private static func adding(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : sum
    }
}
