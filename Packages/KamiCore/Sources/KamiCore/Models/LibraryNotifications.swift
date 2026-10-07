import Foundation

public enum LibraryNotificationAuthorization: Sendable { case notDetermined, denied, allowed }
public enum LibraryNotificationOutcome: String, Sendable { case attempting, submitted, unconfirmed }

public struct LibraryNotificationBatch: Equatable, Sendable {
    public static let identifierPrefix = "app.kami.reader.chapters."
    public let id: UUID
    public let chapterCount: Int
    public let incomplete: Bool
    public var identifier: String { Self.identifierPrefix + id.uuidString }
    public var body: String {
        let count = chapterCount == 1 ? "1 new chapter saved." : "\(chapterCount) new chapters saved."
        return count + (incomplete ? " Some checks did not finish." : "") + " Open Updates to review."
    }
    public static func owns(_ identifier: String) -> Bool {
        guard identifier.utf8.count == identifierPrefix.utf8.count + 36,
              identifier.hasPrefix(identifierPrefix) else { return false }
        let suffix = String(identifier.dropFirst(identifierPrefix.count))
        return suffix.utf8.count == 36 && UUID(uuidString: suffix) != nil
    }
}

public struct LibraryNotificationSettings: Equatable, Sendable {
    public let enabled: Bool
    public let revision: Int64
    public let batch: LibraryNotificationBatch?
    public let outcome: LibraryNotificationOutcome?
}

public enum LibraryNotificationError: Error, Equatable, LocalizedError {
    case settingsChanged, storageUnavailable, busy
    public var errorDescription: String? {
        switch self {
        case .settingsChanged: "Notification settings changed. Reload them before saving."
        case .storageUnavailable: "Notification settings could not be saved or read. Reopen Kami after checking device storage."
        case .busy: "Another notification change is being saved. Try again."
        }
    }
}

/// One notification tap is consumed by one active scene. No persisted manga or
/// chapter identity is carried across a restore, removal or source change.
@MainActor
public final class LibraryNotificationRouter {
    public private(set) var pending: UUID?
    private var seen: [String] = []
    public init() {}
    @discardableResult public func request(identifier: String) -> Bool {
        guard LibraryNotificationBatch.owns(identifier), !seen.contains(identifier) else { return false }
        seen.append(identifier)
        if seen.count > 16 { seen.removeFirst() }
        pending = UUID()
        return true
    }
    public func consume(active: Bool, libraryAvailable: Bool) -> Bool {
        guard active, libraryAvailable, pending != nil else { return false }
        pending = nil
        return true
    }
}
