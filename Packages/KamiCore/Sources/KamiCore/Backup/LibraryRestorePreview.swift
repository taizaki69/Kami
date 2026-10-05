import Foundation

public enum LibraryRestoreError: Error, Equatable, Sendable, LocalizedError {
    case foreignPreview, previewExpired, sourceConflicts, activeWork
    case invalidStoredData, resultLimitExceeded, categoryOrderOverflow, storageUnavailable, importReviewRequired

    public var errorDescription: String? {
        switch self {
        case .foreignPreview: "This preview belongs to another library. Review the backup again."
        case .previewExpired: "The library changed after this preview. Review the backup again before restoring."
        case .sourceConflicts: "Some source addresses conflict. Review the excluded sources before restoring."
        case .activeWork: "Finish or pause active downloads and library checks before restoring."
        case .invalidStoredData: "Some saved library data could not be read safely. No restore was applied."
        case .resultLimitExceeded: "The combined library would exceed the backup limits. No restore was applied."
        case .categoryOrderOverflow: "The saved category order cannot accommodate more categories. Reorder categories and review again."
        case .storageUnavailable: "The restore could not be saved. Your existing library has been kept."
        case .importReviewRequired: "Review the Mihon mapping and exclusions before importing supported data."
        }
    }
}

public struct LibraryRestoreConflict: Identifiable, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case differentDeployment, unresolvedDeployment
    }
    public let sourceID: Int64
    public let reason: Reason
    public let mangaCount: Int
    public let incomingDeployment: String?
    public let storedDeployment: String?
    public var id: Int64 { sourceID }
}

public struct LibraryRestoreSummary: Equatable, Sendable {
    public internal(set) var newManga = 0
    public internal(set) var existingManga = 0
    public internal(set) var newChapters = 0
    public internal(set) var existingChapters = 0
    public internal(set) var newCategories = 0
    public internal(set) var historyEntries = 0
    public internal(set) var excludedManga = 0
    public internal(set) var unresolvedManga = 0
    public var restoredManga: Int { newManga + existingManga }
}

/// Issued only by LibraryStore from a bounded, consistent target snapshot.
/// Public backup DTOs and imported IDs cannot construct this capability.
public struct LibraryRestorePreview: Sendable, Identifiable {
    public let id: UUID
    public let inputSHA256: String
    public let summary: LibraryRestoreSummary
    public let conflicts: [LibraryRestoreConflict]
    public let excludesConflictedSources: Bool
    public let sources: [LibraryBackupDocument.Source]
    public let mihonReport: MihonLibraryImportReport?
    public let acknowledgesMihonLimitations: Bool
    public var canRestore: Bool { restoreBlockReason == nil }
    var restoreBlockReason: LibraryRestoreError? {
        if let report = mihonReport, !acknowledgesMihonLimitations || !report.hasImportableData { return .importReviewRequired }
        return conflicts.isEmpty || excludesConflictedSources ? nil : .sourceConflicts
    }

    let ownerID: UUID
    let epoch: LibraryDataEpoch
    let dependencyDigest: String
    let changeStamp: [Int64]
    let policy: LibraryBackupPolicy
    let plan: LibraryRestorePlan
}

public struct LibraryRestoreReport: Sendable, Equatable {
    public let previewID: UUID
    public let summary: LibraryRestoreSummary
}

struct LibraryRestorePlan: Sendable {
    let document: LibraryBackupDocument
    let summary: LibraryRestoreSummary
    let conflicts: [LibraryRestoreConflict]
    let newFoolSlideBinding: LibraryBackupDocument.ContentBinding?
    let affectedManga: Set<LibraryRestoreMangaIdentity>
}

struct LibraryRestoreMangaIdentity: Hashable, Sendable {
    let source: Int64
    let url: Data
    init(_ manga: LibraryBackupDocument.Manga) { source = manga.sourceID; url = Data(manga.url.utf8) }
}
