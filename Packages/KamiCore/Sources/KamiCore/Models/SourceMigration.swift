import Foundation
import MihonCompatKit

public enum SourceMigrationError: Error, Equatable, Sendable, LocalizedError {
    case invalidDestination, sourceChanged, sameManga, originUnavailable
    case foreignPreview, previewExpired, invalidSelection, activeWork, storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "This destination returned incomplete, duplicate or oversized manga data. Choose another result."
        case .sourceChanged: "The destination source or selection changed. Search again before migrating."
        case .sameManga: "Choose a different manga or source as the destination."
        case .originUnavailable: "The original manga is no longer in your library. Reopen it before migrating."
        case .foreignPreview, .previewExpired: "Your library changed. Prepare a new migration preview before continuing."
        case .invalidSelection: "The selected chapter matches are no longer valid. Prepare a new preview."
        case .activeWork: "Let library updates and downloads finish before migrating."
        case .storageUnavailable: "The migration could not be saved. Your library was kept unchanged."
        }
    }
}

public struct SourceMigrationMatch: Identifiable, Sendable {
    public let id: Int
    public let original: LibraryBackupDocument.Chapter
    public let destination: LibraryBackupDocument.Chapter
}

public struct SourceMigrationUnmatched: Identifiable, Sendable {
    public enum Reason: String, Sendable { case unknownNumber, ambiguousNumber, noDestination }
    public let id: Int
    public let chapter: LibraryBackupDocument.Chapter
    public let reason: Reason
}

/// Suggestions are evidence for review, never proof of identical pagination.
/// URL identity is UTF-8 byte equality; titles and scanlators are display only.
public struct SourceMigrationMatching: Sendable {
    public let matches: [SourceMigrationMatch]
    public let unmatched: [SourceMigrationUnmatched]
    public let unmatchedDestinationCount: Int

    public static func prepare(original: [LibraryBackupDocument.Chapter],
                               destination: [LibraryBackupDocument.Chapter]) throws -> Self {
        let limit = LibraryBackupPolicy.default.maximumChaptersPerManga
        guard original.count <= limit, destination.count <= limit else { throw SourceMigrationError.invalidDestination }
        func index(_ chapters: [LibraryBackupDocument.Chapter]) throws -> [Double: [Int]] {
            var result: [Double: [Int]] = [:], urls = Set<Data>()
            for (i, chapter) in chapters.enumerated() {
                try Task.checkCancellation()
                guard chapter.number.isFinite, !chapter.url.isEmpty, chapter.url.utf8.count <= 4_096,
                      !chapter.url.utf8.contains(0), urls.insert(Data(chapter.url.utf8)).inserted else {
                    throw SourceMigrationError.invalidDestination
                }
                if chapter.number >= 0 { result[chapter.number, default: []].append(i) }
            }
            return result
        }
        let left = try index(original), right = try index(destination)
        var matches: [SourceMigrationMatch] = [], unmatched: [SourceMigrationUnmatched] = []
        for (i, chapter) in original.enumerated() {
            try Task.checkCancellation()
            let reason: SourceMigrationUnmatched.Reason
            if chapter.number < 0 { reason = .unknownNumber }
            else if left[chapter.number]?.count != 1 || (right[chapter.number]?.count ?? 0) > 1 { reason = .ambiguousNumber }
            else if let target = right[chapter.number]?.first {
                matches.append(.init(id: i, original: chapter, destination: destination[target]))
                continue
            } else { reason = .noDestination }
            unmatched.append(.init(id: i, chapter: chapter, reason: reason))
        }
        return .init(matches: matches, unmatched: unmatched,
                     unmatchedDestinationCount: destination.count - matches.count)
    }
}

/// Fetched without writes, bound to the registration and selection that issued
/// the result. Only the store can turn this into a commit-capable preview.
public struct SourceMigrationCandidate: Sendable {
    public let manga: LibraryBackupDocument.Manga
    public let sourceName: String
    public let language: String
    let registration: SourceRegistrationSnapshot
    let selection: SourceDiscoverySelectionSnapshot

    public func checkAvailability() throws {
        guard selection.isCurrent,
              selection.preferences.includes(sourceID: registration.sourceID, language: registration.source.language),
              (try? registration.checkAvailability()) != nil else { throw SourceMigrationError.sourceChanged }
    }

    public static func fetch(registration: SourceRegistrationSnapshot, manga: SMangaCompat,
                             selection: SourceDiscoverySelectionSnapshot) async throws -> Self {
        guard selection.isCurrent,
              selection.preferences.includes(sourceID: registration.sourceID, language: registration.source.language),
              (try? registration.checkAvailability()) != nil else { throw SourceMigrationError.sourceChanged }
        guard !manga.url.isEmpty, manga.url.utf8.count <= 4_096, !manga.url.utf8.contains(0) else {
            throw SourceMigrationError.invalidDestination
        }
        let candidate = try await selection.perform {
            try await registration.perform {
                try Task.checkCancellation()
                let detail = try await registration.source.getMangaDetails(manga: manga)
                try Task.checkCancellation()
                try registration.checkAvailability()
                guard Data(detail.url.utf8) == Data(manga.url.utf8) else { throw SourceMigrationError.invalidDestination }
                let chapters = try await registration.source.getChapterList(manga: detail)
                try Task.checkCancellation()
                return try project(detail: detail, chapters: chapters, registration: registration, selection: selection)
            }
        }
        try Task.checkCancellation()
        try candidate.checkAvailability()
        return candidate
    }

    static func project(detail: SMangaCompat, chapters: [SChapterCompat],
                        registration: SourceRegistrationSnapshot, selection: SourceDiscoverySelectionSnapshot) throws -> Self {
        guard !chapters.isEmpty, chapters.count <= LibraryBackupPolicy.default.maximumChaptersPerManga else {
            throw SourceMigrationError.invalidDestination
        }
        let value = LibraryBackupDocument.Manga(sourceID: registration.sourceID, url: detail.url,
            title: detail.title, altTitles: detail.altTitles, thumbnailURL: detail.thumbnailURL,
            author: detail.author, artist: detail.artist, descriptionText: detail.description,
            genres: detail.genres, status: detail.status, inLibrary: true,
            updateStrategy: detail.updateStrategy, initialized: true,
            chapters: chapters.enumerated().map { order, chapter in
                .init(sourceOrder: Int64(order), url: chapter.url, name: chapter.name, scanlator: chapter.scanlators.first,
                      number: Double(chapter.number ?? "") ?? Double(chapter.chapterNumber), dateUpload: chapter.dateUpload)
            })
        // Pure validation only. This descriptive unresolved binding cannot
        // install, configure or alter the stored deployment namespace.
        let document = LibraryBackupDocument(exportID: UUID(), exportedAt: 0,
            sources: [.init(sourceID: registration.sourceID, name: registration.source.name,
                            language: registration.source.language, contentBinding: .init(kind: .unresolved))],
            manga: [value])
        do { try LibraryBackupCodec().validate(document) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SourceMigrationError.invalidDestination }
        return .init(manga: value, sourceName: registration.source.name, language: registration.source.language,
                     registration: registration, selection: selection)
    }
}

/// Immutable, store-issued approval data. A list of selected match IDs can
/// only narrow these reviewed suggestions, never inject another chapter URL.
public struct SourceMigrationPreview: Identifiable, Sendable {
    public let id: UUID
    public let original: LibraryBackupDocument.Manga
    public let destination: SourceMigrationCandidate
    public let destinationExists: Bool
    public let matching: SourceMigrationMatching
    public let categoryNames: [String]
    let ownerID: UUID
    let originID: Int64
    let epoch: LibraryDataEpoch
    let dependencyDigest: String
    let changeStamp: [Int64]
    let expectedConfiguration: ExtensionExecutionConfiguration?

    func validateSelection(_ selected: Set<Int>) throws {
        guard selected.isSubset(of: Set(matching.matches.map(\.id))) else { throw SourceMigrationError.invalidSelection }
    }
}

public struct SourceMigrationReport: Sendable {
    public let previewID: UUID
    public let destinationMangaID: Int64
    public let selectedChapters: Int
}
