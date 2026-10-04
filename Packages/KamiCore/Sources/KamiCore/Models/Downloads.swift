import Foundation
import MihonCompatKit

public struct DownloadPolicy: Equatable, Sendable {
    public let maximumPageCount: Int
    public let maximumPageBytes: Int
    public let maximumChapterBytes: Int64
    public let quotaBytes: Int64
    public let freeSpaceFloorBytes: Int64
    public let maximumManifestBytes: Int
    public let maximumJobs: Int

    public init(
        maximumPageCount: Int = 2_048,
        maximumPageBytes: Int = 32 * 1024 * 1024,
        maximumChapterBytes: Int64 = 512 * 1024 * 1024,
        quotaBytes: Int64 = 2 * 1024 * 1024 * 1024,
        freeSpaceFloorBytes: Int64 = 256 * 1024 * 1024,
        maximumManifestBytes: Int = 1024 * 1024,
        maximumJobs: Int = 10_000
    ) {
        self.maximumPageCount = max(1, min(2_048, maximumPageCount))
        self.maximumPageBytes = max(1, min(32 * 1024 * 1024, maximumPageBytes))
        self.maximumChapterBytes = max(1, min(512 * 1024 * 1024, maximumChapterBytes))
        self.quotaBytes = max(1, min(2 * 1024 * 1024 * 1024, quotaBytes))
        self.freeSpaceFloorBytes = max(0, min(256 * 1024 * 1024, freeSpaceFloorBytes))
        self.maximumManifestBytes = max(1, min(1024 * 1024, maximumManifestBytes))
        self.maximumJobs = max(1, min(10_000, maximumJobs))
    }
}

/// Identifies generated app-owned content. It is data, never an execution token.
public struct DownloadContentIdentity: Codable, Equatable, Hashable, Sendable {
    public let jobID: UUID
    public let attemptID: UUID
    public let mangaID: Int64
    public let chapterID: Int64
    public let sourceID: Int64
    public let mangaURLDigest: String
    public let chapterURLDigest: String

    public init(jobID: UUID, attemptID: UUID, mangaID: Int64, chapterID: Int64,
                sourceID: Int64, mangaURLDigest: String, chapterURLDigest: String) {
        self.jobID = jobID
        self.attemptID = attemptID
        self.mangaID = mangaID
        self.chapterID = chapterID
        self.sourceID = sourceID
        self.mangaURLDigest = mangaURLDigest
        self.chapterURLDigest = chapterURLDigest
    }
}

public struct DownloadPageReceipt: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let byteCount: Int64
    public let sha256: String

    public init(ordinal: Int, byteCount: Int64, sha256: String) {
        self.ordinal = ordinal
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum DownloadFailureReason: String, Codable, Sendable {
    case sourceUnavailable, configurationChanged, mangaRemoved, chapterUnavailable
    case pageListInvalid, imageRequestUnavailable, imageInvalid, transferFailed
    case quotaExceeded, diskSpaceLow, storageUnavailable, bundleCorrupt
    case legacyUnverified, interrupted, paused, cancelled
}

public struct DownloadTarget: Equatable, Sendable {
    public let manga: Manga
    public let chapter: Chapter
    public let isCurrentChapter: Bool
}

/// Only LibraryStore can issue this token. Codable content identities and
/// filesystem receipts cannot recreate its CAS or authenticated configuration.
public struct DownloadAttempt: Sendable {
    public let identity: DownloadContentIdentity
    public let revision: Int64
    public let manga: Manga
    public let chapter: Chapter
    public let policy: DownloadPolicy
    let libraryRevision: Int64
    let expectedConfiguration: ExtensionExecutionConfiguration?

    public var jobID: UUID { identity.jobID }
    public var attemptID: UUID { identity.attemptID }
}

/// Database evidence only. Filesystem validation is still required before use.
public struct CompletedDownloadBundle: Equatable, Sendable {
    public let identity: DownloadContentIdentity
    public let manifestSHA256: String
    public let pages: [DownloadPageReceipt]
    public let totalBytes: Int64
    public let manga: Manga
    public let chapter: Chapter
    public let isCurrentChapter: Bool
}

public struct DownloadItem: Identifiable, Equatable, Sendable {
    public let jobID: UUID
    public let revision: Int64
    public let state: DownloadState
    public let manga: Manga
    public let chapter: Chapter
    public let isCurrentChapter: Bool
    public let contentIdentity: DownloadContentIdentity?
    public let pageCount: Int?
    public let completedPages: Int
    /// Compressed page bytes retained until filesystem cleanup is acknowledged.
    public let storedBytes: Int64
    public let reason: DownloadFailureReason?
    public let manifestSHA256: String?
    public let queueOrder: Int64
    public let createdAt: Int64
    public let updatedAt: Int64

    public var id: UUID { jobID }
    public var attemptID: UUID? { contentIdentity?.attemptID }
}

public struct DownloadQueueSummary: Equatable, Sendable {
    public let queued: Int
    public let active: Int
    public let finished: Int
    public let paused: Int
    public let failed: Int
    public let cancelled: Int
    public let deleting: Int
    public let storedBytes: Int64
    public let cleanupBytes: Int64
    public let quotaBytes: Int64

    public var totalJobs: Int { queued + active + finished + paused + failed + cancelled + deleting }
}

public struct DownloadQueueCursor: Equatable, Sendable {
    public let queueOrder: Int64
    public let jobID: UUID
}

public struct DownloadQueueSnapshot: Equatable, Sendable {
    public let items: [DownloadItem]
    public let summary: DownloadQueueSummary
    public let hasMore: Bool
    public let nextCursor: DownloadQueueCursor?
}

public struct DownloadMutation: Sendable {
    public let item: DownloadItem?
    public let cleanup: [DownloadContentIdentity]
}

public struct DownloadRecovery: Sendable {
    public let interruptedJobs: Int
    public let cleanup: [DownloadContentIdentity]
}

public struct DownloadChapterState: Equatable, Sendable {
    public let jobID: UUID
    public let state: DownloadState
    public let reason: DownloadFailureReason?
}

public enum DownloadPersistenceError: Error, Equatable, Sendable, LocalizedError {
    case jobNotFound, chapterNotFound, mangaNotInLibrary, chapterNotCurrent
    case sourceIdentityMismatch, staleAttempt, invalidState, activeAttemptExists
    case invalidReceipt, pageLimitExceeded, chapterLimitExceeded, queueLimitExceeded
    case incompletePages, manifestMismatch, cleanupPending, invalidStoredRecord
    case storageUnavailable, selectionTooLarge

    public var errorDescription: String? {
        switch self {
        case .jobNotFound: "The download is unavailable."
        case .chapterNotFound: "The chapter is unavailable."
        case .mangaNotInLibrary: "This manga is no longer in your library."
        case .chapterNotCurrent: "This chapter is no longer in the current catalog."
        case .sourceIdentityMismatch: "The download source no longer matches this chapter."
        case .staleAttempt: "This download attempt is no longer current."
        case .invalidState: "The download cannot perform this action."
        case .activeAttemptExists: "A download is already running."
        case .invalidReceipt: "The downloaded page is invalid."
        case .pageLimitExceeded: "The chapter exceeds the page download limit."
        case .chapterLimitExceeded: "The chapter exceeds the download size limit."
        case .queueLimitExceeded: "The download queue is full."
        case .incompletePages: "The chapter download is incomplete."
        case .manifestMismatch: "The download manifest does not match its pages."
        case .cleanupPending: "The previous download files still need cleanup."
        case .invalidStoredRecord: "The stored download is invalid."
        case .storageUnavailable: "The download could not be stored."
        case .selectionTooLarge: "Too many chapters were requested at once."
        }
    }
}
