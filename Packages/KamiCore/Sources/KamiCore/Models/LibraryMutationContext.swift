import Foundation

/// Issued with stored values before an operation is scheduled. Retained work
/// must keep this context; obtaining a new one must never rebase an old intent.
public struct LibraryMutationContext: Equatable, Sendable {
    let ownerID: UUID
    let epoch: LibraryDataEpoch

    init(ownerID: UUID, epoch: LibraryDataEpoch) {
        self.ownerID = ownerID
        self.epoch = epoch
    }
}

/// A new source detail may have no stored manga yet. Its context still names
/// the database generation observed before the first provider request.
public struct SourceMangaSnapshot: Sendable {
    public let reading: MangaReadingSnapshot?
    public let mutationContext: LibraryMutationContext
}

public enum LibraryMutationError: Error, Equatable, Sendable, LocalizedError {
    case snapshotUnavailable
    case foreignContext
    case staleEpoch
    case invalidStoredState
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            "The saved library has not loaded. Reload it before making changes."
        case .foreignContext, .staleEpoch:
            "The library changed. Reopen this screen before making changes."
        case .invalidStoredState:
            "The saved library generation is invalid. These changes could not be saved."
        case .storageUnavailable:
            "The saved library is temporarily unavailable. Please try again."
        }
    }
}
