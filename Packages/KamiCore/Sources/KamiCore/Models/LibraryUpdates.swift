import Foundation

public enum LibraryUpdateScanStatus: String, Codable, Sendable {
    case running, completed, cancelled, interrupted
}

/// Counters describe durable, mutually exclusive outcomes for the captured
/// targets. Baselines are a subset of checked; they never count as discoveries.
public struct LibraryUpdateSummary: Equatable, Sendable {
    public let scanID: UUID
    public let status: LibraryUpdateScanStatus
    public let startedAt: Int64
    public let finishedAt: Int64?
    public let total: Int
    public let checked: Int
    public let newChapters: Int
    public let baselines: Int
    public let skipped: Int
    public let failed: Int
    public let cancelled: Int

    public var processedCount: Int { checked + skipped + failed + cancelled }
}

public struct LibraryUpdateItem: Equatable, Sendable {
    public let manga: Manga
    public let hasSuccessfulBaseline: Bool
}

public struct LibraryUpdateScanSnapshot: Equatable, Sendable {
    public let record: LibraryUpdateSummary
    public let items: [LibraryUpdateItem]
}

public enum LibraryUpdateCommitOutcome: Equatable, Sendable {
    case updated(newChapters: Int, establishedBaseline: Bool)
    case skippedNotInLibrary
}

public struct LibraryUpdateCommitResult: Equatable, Sendable {
    public let summary: LibraryUpdateSummary
    public let outcome: LibraryUpdateCommitOutcome
}

/// The chapter identity remains stable when it disappears and returns.
public struct LibraryChapterDiscovery: Identifiable, Equatable, Sendable {
    public let manga: Manga
    public let chapter: Chapter
    public let detectedAt: Int64

    /// An opaque ASCII key keeps SwiftUI/set equality faithful to URL bytes.
    public var id: String { "\(chapter.mangaId):\(Data(chapter.url.utf8).base64EncodedString())" }
}

public struct LibraryChapterDiscoveryCursor: Equatable, Sendable {
    public let detectedAt: Int64
    public let mangaID: Int64
    public let chapterURL: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.detectedAt == rhs.detectedAt && lhs.mangaID == rhs.mangaID
            && Data(lhs.chapterURL.utf8) == Data(rhs.chapterURL.utf8)
    }
}

public enum LibraryUpdateTargetOutcome: String, Sendable {
    case pending, checked, skipped, failed, cancelled
}

public enum LibraryUpdateTargetReason: String, Codable, Sendable {
    case sourceUnavailable, configurationChanged, onlyFetchOnce
    case requestFailed, removedFromLibrary, cancelled
}

public struct LibraryUpdateIssue: Equatable, Sendable {
    public let mangaID: Int64
    public let title: String
    public let manga: Manga?
    public let outcome: LibraryUpdateTargetOutcome
    public let reason: LibraryUpdateTargetReason
}

public struct LibraryUpdatesSnapshot: Equatable, Sendable {
    public let latestScan: LibraryUpdateSummary?
    public let latestScanIssues: [LibraryUpdateIssue]
    public let discoveries: [LibraryChapterDiscovery]
    public let hasMore: Bool
    public let nextCursor: LibraryChapterDiscoveryCursor?
}

/// Finite errors keep source URLs and arbitrary transport/parser text out of
/// persisted summaries and user-facing scan diagnostics.
public enum LibraryUpdatePersistenceError: Error, Equatable, Sendable, LocalizedError {
    case scanAlreadyRunning
    case scanNotFound
    case scanNotRunning
    case mangaNotInScan
    case targetAlreadyRecorded
    case sourceIdentityMismatch
    case invalidTerminalStatus
    case unfinishedTargets
    case invalidTargetReason
    case invalidStoredScan

    public var errorDescription: String? {
        switch self {
        case .scanAlreadyRunning: "A library update is already running."
        case .scanNotFound: "The library update is unavailable."
        case .scanNotRunning: "This library update is no longer running."
        case .mangaNotInScan: "This manga is not part of the library update."
        case .targetAlreadyRecorded: "This manga already has an update outcome."
        case .sourceIdentityMismatch: "The source result no longer matches this manga."
        case .invalidTerminalStatus: "The library update cannot use this status."
        case .unfinishedTargets: "The library update still has unfinished manga."
        case .invalidTargetReason: "The library update outcome has an invalid reason."
        case .invalidStoredScan: "The stored library update is invalid."
        }
    }
}
