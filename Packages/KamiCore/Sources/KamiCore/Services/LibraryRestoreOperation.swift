import Foundation

#if canImport(SQLite3)
public struct LibraryRestoreCompletion: Sendable {
    public let report: LibraryRestoreReport
    public let presentationPublished: Bool
}

extension LibraryOperationCoordinator {
    /// Reserve synchronously, before scheduling the owned operation. Dropping
    /// an observer does not cancel it or release exclusion before it drains.
    public func startLibraryRestore(
        store: LibraryStore, preview: LibraryRestorePreview,
        expected: LibraryPresentationGeneration
    ) throws -> Task<LibraryRestoreCompletion, Error> {
        guard preview.canRestore else { throw LibraryRestoreError.sourceConflicts }
        let exclusive = try beginExclusive(expected: expected)
        return Task { @MainActor in
            defer { try? self.finishExclusive(exclusive) }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { try await store.commitLibraryRestore(preview) }
            let report = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            // COMMIT is definitive. Late cancellation must not report rollback
            // or suppress the generation that invalidates old readers/routes.
            let published: Bool
            do { try self.publishCommittedChange(exclusive); published = true }
            catch { published = false }
            return .init(report: report, presentationPublished: published)
        }
    }
}
#endif
