import Foundation
import MihonCompatKit

public enum SourceCompatibilityDiagnosticsError: Error, Sendable, LocalizedError {
    case unavailable
    public var errorDescription: String? { "A runtime compatibility report is not available for this source." }
}

public struct SourceCompatibilityReport: Sendable {
    public let sourceID: Int64
    public let registrationID: UUID
    public let revision: UInt64
    public let export: InterpretedCompatibilityExport
}

public enum SourceCompatibilityDiagnostics {
    /// Local snapshot only: no source operation is executed to manufacture a
    /// diagnostic. Off-main work is cancelled and awaited before returning.
    public static func prepare(registration: SourceRegistrationSnapshot) async throws -> SourceCompatibilityReport {
        try Task.checkCancellation()
        try registration.checkAvailability()
        guard let reporting = registration.source as? any InterpretedCompatibilityReportingSource else {
            throw SourceCompatibilityDiagnosticsError.unavailable
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try registration.checkAvailability()
            let report = reporting.compatibilityReport()
            try Task.checkCancellation()
            let exported = try InterpretedCompatibilityExport.prepare(report)
            try registration.checkAvailability()
            try Task.checkCancellation()
            return SourceCompatibilityReport(sourceID: registration.sourceID,
                registrationID: registration.registrationID, revision: registration.revision, export: exported)
        }
        return try await withTaskCancellationHandler {
            let report = try await worker.value
            try Task.checkCancellation()
            try registration.checkAvailability()
            return report
        } onCancel: { worker.cancel() }
    }
}
