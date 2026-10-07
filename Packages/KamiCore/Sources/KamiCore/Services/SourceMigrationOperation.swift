import Foundation

#if canImport(SQLite3)
public struct SourceMigrationCompletion: Sendable {
    public let report: SourceMigrationReport
    public let presentationPublished: Bool
}

extension LibraryOperationCoordinator {
    public func startSourceMigration(store: LibraryStore, preview: SourceMigrationPreview,
                                     selectedMatches: Set<Int>, copyCategories: Bool,
                                     expected: LibraryPresentationGeneration) throws -> Task<SourceMigrationCompletion, Error> {
        try startSourceMigration(store: store, preview: preview, selection: preview.suggestedSelection(selectedMatches),
                                 copyCategories: copyCategories, expected: expected)
    }

    public func startSourceMigration(store: LibraryStore, preview: SourceMigrationPreview,
                                     selection: SourceMigrationSelection, copyCategories: Bool,
                                     expected: LibraryPresentationGeneration) throws -> Task<SourceMigrationCompletion, Error> {
        _ = try preview.resolvedMatches(selection)
        try preview.destination.checkAvailability()
        let exclusive = try beginExclusive(expected: expected)
        return Task { @MainActor in
            defer { try? self.finishExclusive(exclusive) }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try await store.commitSourceMigration(preview, selection: selection, copyCategories: copyCategories)
            }
            let report = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            // COMMIT is final, including cancellation arriving at publication.
            let published: Bool
            do { try self.publishCommittedChange(exclusive); published = true }
            catch { published = false }
            return .init(report: report, presentationPublished: published)
        }
    }
}
#endif
