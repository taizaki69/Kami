import Foundation

/// An opaque database generation, issued only with a stored reading snapshot.
/// It is deliberately neither serializable nor constructible by API consumers.
public struct LibraryDataEpoch: Equatable, Sendable {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
}

/// Captures the exact stored identities and the store that issued them. A row
/// ID alone is insufficient authority to update a retained reader session.
public struct ChapterWriteTarget: Equatable, Sendable {
    let ownerID: UUID
    let epoch: LibraryDataEpoch
    public let mangaID: Int64
    public let chapterID: Int64
    public let sourceID: Int64
    private let mangaURLBytes: Data
    private let chapterURLBytes: Data

    public var mangaURL: String { String(decoding: mangaURLBytes, as: UTF8.self) }
    public var chapterURL: String { String(decoding: chapterURLBytes, as: UTF8.self) }

    init(ownerID: UUID, epoch: LibraryDataEpoch, mangaID: Int64, chapterID: Int64,
         sourceID: Int64, mangaURL: String, chapterURL: String) {
        self.ownerID = ownerID; self.epoch = epoch
        self.mangaID = mangaID; self.chapterID = chapterID; self.sourceID = sourceID
        self.mangaURLBytes = Data(mangaURL.utf8); self.chapterURLBytes = Data(chapterURL.utf8)
    }

    func matches(mangaURL: String, chapterURL: String) -> Bool {
        mangaURLBytes == Data(mangaURL.utf8) && chapterURLBytes == Data(chapterURL.utf8)
    }
}

/// Models and targets are obtained in one database read transaction. The target
/// map covers the union of current, downloaded, and explicitly requested rows.
/// Downloaded membership describes saved state; file leases still need their
/// independent manifest and receipt checks.
public struct MangaReadingSnapshot: Equatable, Sendable {
    public let manga: Manga
    public let epoch: LibraryDataEpoch
    public let mutationContext: LibraryMutationContext
    public let currentChapters: [Chapter]
    public let downloadedChapters: [Chapter]
    public let requestedChapter: Chapter?
    public let targets: [Int64: ChapterWriteTarget]

    public func target(for chapterID: Int64) -> ChapterWriteTarget? { targets[chapterID] }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.manga == rhs.manga && Data(lhs.manga.url.utf8) == Data(rhs.manga.url.utf8)
            && lhs.epoch == rhs.epoch && lhs.mutationContext == rhs.mutationContext
            && lhs.currentChapters == rhs.currentChapters
            && lhs.downloadedChapters == rhs.downloadedChapters
            && lhs.requestedChapter == rhs.requestedChapter && lhs.targets == rhs.targets
    }
}

public struct ReadingProgressResult: Equatable, Sendable {
    public let chapter: Chapter
    public let lastRead: Int64
    public let readDuration: Int64
}

/// Finite errors never expose SQL, saved URLs, or other database contents.
public enum ReadingStateError: Error, Equatable, Sendable, LocalizedError {
    case storageUnavailable
    case invalidStoredData
    case limitExceeded
    case invalidInput
    case foreignTarget
    case staleEpoch
    case identityChanged
    case mangaNotFound
    case chapterNotFound

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "The saved reading state is temporarily unavailable."
        case .invalidStoredData: return "The saved reading state could not be read faithfully."
        case .limitExceeded: return "The saved reading state exceeds the reader limits."
        case .invalidInput: return "The requested reading state is invalid."
        case .foreignTarget, .staleEpoch, .identityChanged:
            return "This reading session is no longer current. Close and reopen the reader."
        case .mangaNotFound: return "The saved manga is no longer available. Close and reopen the reader."
        case .chapterNotFound: return "The saved chapter is no longer available. Close and reopen the reader."
        }
    }
}
