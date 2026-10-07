import Foundation

public struct SourceMigrationPair: Identifiable, Equatable, Sendable {
    public let originalIndex: Int
    public let destinationIndex: Int
    public var id: Int { originalIndex }
}

/// A value snapshot of the user's current pairs, scoped to one store preview.
/// Public callers obtain it from the draft, never from arbitrary URL strings.
public struct SourceMigrationSelection: Sendable {
    let previewID: UUID
    let pairs: [SourceMigrationPair]
    public var count: Int { pairs.count }
}

/// Editing changes only this local value, not the database or the preview.
/// Source and destination indices are bounded by that preview's immutable lists.
public struct SourceMigrationDraft: Sendable {
    private let previewID: UUID
    public let originalCount: Int
    public let destinationCount: Int
    private let suggestions: [Int: Int]
    private var byOriginal: [Int: Int]
    private var byDestination: [Int: Int]
    public private(set) var revision = UUID()

    init(previewID: UUID, originalCount: Int, destinationCount: Int, suggestions: [SourceMigrationMatch]) {
        self.previewID = previewID
        self.originalCount = originalCount
        self.destinationCount = destinationCount
        self.suggestions = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0.destinationIndex) })
        byOriginal = self.suggestions
        byDestination = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.destinationIndex, $0.id) })
    }

    public var pairs: [SourceMigrationPair] {
        byOriginal.keys.sorted().compactMap { origin in
            byOriginal[origin].map { .init(originalIndex: origin, destinationIndex: $0) }
        }
    }
    public var selection: SourceMigrationSelection { .init(previewID: previewID, pairs: pairs) }
    public var matchedCount: Int { byOriginal.count }
    public var unmatchedOriginalCount: Int { originalCount - matchedCount }
    public var unmatchedDestinationCount: Int { destinationCount - matchedCount }
    public var matchedOriginalIndices: Set<Int> { Set(byOriginal.keys) }
    public var matchedDestinationIndices: Set<Int> { Set(byDestination.keys) }
    public var manualCount: Int { byOriginal.filter { suggestions[$0.key] != $0.value }.count }
    public func destination(for original: Int) -> Int? { byOriginal[original] }
    public func original(for destination: Int) -> Int? { byDestination[destination] }
    public func isNumberSuggestion(_ pair: SourceMigrationPair) -> Bool {
        suggestions[pair.originalIndex] == pair.destinationIndex
    }

    /// Conflicts fail atomically; assigning an occupied target never silently
    /// removes another user's choice, even when replacing an existing pair.
    public mutating func assign(destination: Int?, to original: Int) throws {
        guard (0..<originalCount).contains(original),
              destination.map({ (0..<destinationCount).contains($0) }) ?? true else {
            throw SourceMigrationError.invalidSelection
        }
        if let destination, let owner = byDestination[destination], owner != original {
            throw SourceMigrationError.destinationAlreadyMatched
        }
        guard byOriginal[original] != destination else { return }
        if let previous = byOriginal.removeValue(forKey: original) { byDestination.removeValue(forKey: previous) }
        if let destination {
            byOriginal[original] = destination
            byDestination[destination] = original
        }
        revision = UUID()
    }

    public mutating func resetToSuggestions() {
        guard byOriginal != suggestions else { return }
        byOriginal = suggestions
        byDestination = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.value, $0.key) })
        revision = UUID()
    }
}

public enum SourceMigrationChapterSearchError: Error, Equatable, Sendable, LocalizedError {
    case queryTooLong, invalidInput
    public var errorDescription: String? {
        switch self {
        case .queryTooLong: "Use a shorter chapter search (up to 256 UTF-8 bytes)."
        case .invalidInput: "The chapter list cannot be searched. Reopen the migration preview."
        }
    }
}

public struct SourceMigrationChapterSearch: Sendable, Equatable {
    public static let pageSize = 100
    public let indices: [Int]
    public let totalMatches: Int
    public let page: Int
    public var hasNextPage: Bool { (page + 1) * Self.pageSize < totalMatches }

    /// Pure, cancellable search over bounded display fields. It never folds
    /// identity URLs, starts a provider or changes a chapter's preview index.
    public static func search(chapters: [LibraryBackupDocument.Chapter], query: String,
                              excluding: Set<Int> = [], page: Int = 0) throws -> Self {
        try Task.checkCancellation()
        guard query.utf8.count <= 256 else { throw SourceMigrationChapterSearchError.queryTooLong }
        let policy = LibraryBackupPolicy.default
        guard chapters.count <= policy.maximumChaptersPerManga, page >= 0,
              page < policy.maximumChaptersPerManga / pageSize, excluding.count <= chapters.count,
              excluding.allSatisfy(chapters.indices.contains) else { throw SourceMigrationChapterSearchError.invalidInput }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = Locale(identifier: "en_US_POSIX"), offset = page * pageSize
        var indices: [Int] = [], count = 0, totalBytes = 0
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let nameBytes = chapter.name.utf8.count, scanlatorBytes = chapter.scanlator?.utf8.count ?? 0
            guard chapter.number.isFinite, nameBytes <= policy.maximumMetadataBytes, scanlatorBytes <= policy.maximumMetadataBytes,
                  nameBytes + scanlatorBytes <= policy.maximumTotalStringBytes - totalBytes else {
                throw SourceMigrationChapterSearchError.invalidInput
            }
            totalBytes += nameBytes + scanlatorBytes
            guard !excluding.contains(index) else { continue }
            let fields = [chapter.name, chapter.scanlator ?? "", chapter.number >= 0 ? String(chapter.number) : ""]
            guard query.isEmpty || fields.contains(where: {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            }) else { continue }
            if count >= offset, indices.count < pageSize { indices.append(index) }
            count += 1
        }
        try Task.checkCancellation()
        return .init(indices: indices, totalMatches: count, page: page)
    }
}
