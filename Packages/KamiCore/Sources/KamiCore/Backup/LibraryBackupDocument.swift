import Foundation
import MihonCompatKit

/// Portable stored library data. Constructing or decoding this value does not
/// authorize a restore, install a source, or make its content binding trusted.
/// Dates retain their persisted per-field units; only exportedAt is seconds.
public struct LibraryBackupDocument: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        case allStoredDomainRows
    }

    public let format = "kami.library"
    public let version = 1
    public let exportID: UUID
    public let exportedAt: Int64
    public let scope: Scope = .allStoredDomainRows
    public let sources: [Source]
    public let categories: [Category]
    public let manga: [Manga]

    public init(exportID: UUID, exportedAt: Int64, sources: [Source] = [],
                categories: [Category] = [], manga: [Manga] = []) {
        self.exportID = exportID
        self.exportedAt = exportedAt
        self.sources = sources
        self.categories = categories
        self.manga = manga
    }

    /// Descriptive data only. A deployment URL never supplies runtime settings.
    public struct ContentBinding: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case sourceIdentity, deployment, unresolved
        }
        public let kind: Kind
        public let deploymentURL: String?

        public init(kind: Kind = .sourceIdentity, deploymentURL: String? = nil) {
            self.kind = kind
            self.deploymentURL = deploymentURL
        }
    }

    public struct Source: Sendable, Equatable {
        public let sourceID: Int64
        public let name: String
        public let language: String?
        public let packageHint: String?
        public let contentBinding: ContentBinding

        public init(sourceID: Int64, name: String, language: String? = nil,
                    packageHint: String? = nil, contentBinding: ContentBinding = .init()) {
            self.sourceID = sourceID
            self.name = name
            self.language = language
            self.packageHint = packageHint
            self.contentBinding = contentBinding
        }
    }

    /// key is local to this archive, never an imported SQLite row ID.
    public struct Category: Sendable, Equatable {
        public let key: String
        public let name: String
        public let sortOrder: Int64
        public let flags: Int64

        public init(key: String, name: String, sortOrder: Int64 = 0, flags: Int64 = 0) {
            self.key = key
            self.name = name
            self.sortOrder = sortOrder
            self.flags = flags
        }
    }

    public struct Manga: Sendable, Equatable {
        public let sourceID: Int64
        public let url: String
        public let title: String
        public let altTitles: [String]
        public let thumbnailURL: String?
        public let author: String?
        public let artist: String?
        public let descriptionText: String?
        public let genres: [String]
        public let status: MangaStatus
        public let inLibrary: Bool
        public let dateAdded: Int64
        public let dateUpdated: Int64
        public let lastFetched: Int64
        public let updateStrategy: UpdateStrategy
        public let initialized: Bool
        public let categoryKeys: [String]
        public let chapters: [Chapter]
        public let history: [History]
        public let discoveryBaseline: DiscoveryBaseline?
        public let knownChapters: [KnownChapter]

        public init(sourceID: Int64, url: String, title: String = "",
                    altTitles: [String] = [], thumbnailURL: String? = nil,
                    author: String? = nil, artist: String? = nil,
                    descriptionText: String? = nil, genres: [String] = [],
                    status: MangaStatus = .unknown, inLibrary: Bool = false,
                    dateAdded: Int64 = 0, dateUpdated: Int64 = 0, lastFetched: Int64 = 0,
                    updateStrategy: UpdateStrategy = .alwaysUpdate, initialized: Bool = false,
                    categoryKeys: [String] = [], chapters: [Chapter] = [],
                    history: [History] = [], discoveryBaseline: DiscoveryBaseline? = nil,
                    knownChapters: [KnownChapter] = []) {
            self.sourceID = sourceID
            self.url = url
            self.title = title
            self.altTitles = altTitles
            self.thumbnailURL = thumbnailURL
            self.author = author
            self.artist = artist
            self.descriptionText = descriptionText
            self.genres = genres
            self.status = status
            self.inLibrary = inLibrary
            self.dateAdded = dateAdded
            self.dateUpdated = dateUpdated
            self.lastFetched = lastFetched
            self.updateStrategy = updateStrategy
            self.initialized = initialized
            self.categoryKeys = categoryKeys
            self.chapters = chapters
            self.history = history
            self.discoveryBaseline = discoveryBaseline
            self.knownChapters = knownChapters
        }
    }

    public struct Chapter: Sendable, Equatable {
        public let sourceOrder: Int64
        public let url: String
        public let name: String
        public let scanlator: String?
        public let number: Double
        public let dateUpload: Int64
        public let dateFetch: Int64
        public let read: Bool
        public let bookmark: Bool
        public let lastPageRead: Int64
        public let isCurrent: Bool

        public init(sourceOrder: Int64 = 0, url: String, name: String,
                    scanlator: String? = nil, number: Double = -1,
                    dateUpload: Int64 = 0, dateFetch: Int64 = 0,
                    read: Bool = false, bookmark: Bool = false,
                    lastPageRead: Int64 = 0, isCurrent: Bool = true) {
            self.sourceOrder = sourceOrder
            self.url = url
            self.name = name
            self.scanlator = scanlator
            self.number = number
            self.dateUpload = dateUpload
            self.dateFetch = dateFetch
            self.read = read
            self.bookmark = bookmark
            self.lastPageRead = lastPageRead
            self.isCurrent = isCurrent
        }
    }

    public struct History: Sendable, Equatable {
        public let chapterURL: String
        public let lastRead: Int64
        public let readDuration: Int64

        public init(chapterURL: String, lastRead: Int64 = 0, readDuration: Int64 = 0) {
            self.chapterURL = chapterURL
            self.lastRead = lastRead
            self.readDuration = readDuration
        }
    }

    /// nil and an establishedAt of zero describe different discovery states.
    public struct DiscoveryBaseline: Sendable, Equatable {
        public let establishedAt: Int64
        public init(establishedAt: Int64) { self.establishedAt = establishedAt }
    }

    /// A known URL need not have a physical chapter row in the archive.
    public struct KnownChapter: Sendable, Equatable {
        public let url: String
        public let firstSeen: Int64
        public let detectedAt: Int64?

        public init(url: String, firstSeen: Int64, detectedAt: Int64? = nil) {
            self.url = url
            self.firstSeen = firstSeen
            self.detectedAt = detectedAt
        }
    }
}

/// Immutable ceilings. An injected policy can only lower the built-in limits.
public struct LibraryBackupPolicy: Sendable, Equatable {
    public let maximumInputBytes: Int
    public let maximumDepth: Int
    public let maximumJSONValues: Int
    public let maximumJSONStringBytes: Int
    public let maximumJSONObjectKeys: Int
    public let maximumJSONArrayElements: Int
    public let maximumManga: Int
    public let maximumSources: Int
    public let maximumCategories: Int
    public let maximumChapters: Int
    public let maximumHistory: Int
    public let maximumKnownChapters: Int
    public let maximumMemberships: Int
    public let maximumChaptersPerManga: Int
    public let maximumAlternateTitles: Int
    public let maximumGenres: Int
    public let maximumURLBytes: Int
    public let maximumLabelBytes: Int
    public let maximumMetadataBytes: Int
    public let maximumDescriptionBytes: Int
    public let maximumTotalStringBytes: Int

    public static let `default` = LibraryBackupPolicy()

    private init() {
        maximumInputBytes = 64 * 1024 * 1024
        maximumDepth = 32
        maximumJSONValues = 4_000_000
        maximumJSONStringBytes = 64 * 1024 * 1024
        maximumJSONObjectKeys = 64
        maximumJSONArrayElements = 100_000
        maximumManga = 10_000
        maximumSources = 10_000
        maximumCategories = 1_000
        maximumChapters = 100_000
        maximumHistory = 100_000
        maximumKnownChapters = 100_000
        maximumMemberships = 100_000
        maximumChaptersPerManga = 20_000
        maximumAlternateTitles = 256
        maximumGenres = 256
        maximumURLBytes = 4_096
        maximumLabelBytes = 1_024
        maximumMetadataBytes = 8_192
        maximumDescriptionBytes = 256 * 1024
        maximumTotalStringBytes = 32 * 1024 * 1024
    }

    public init(maximumInputBytes: Int = 64 * 1024 * 1024, maximumDepth: Int = 32,
                maximumJSONValues: Int = 4_000_000, maximumJSONStringBytes: Int = 64 * 1024 * 1024,
                maximumJSONObjectKeys: Int = 64, maximumJSONArrayElements: Int = 100_000,
                maximumManga: Int = 10_000, maximumSources: Int = 10_000,
                maximumCategories: Int = 1_000, maximumChapters: Int = 100_000,
                maximumHistory: Int = 100_000, maximumKnownChapters: Int = 100_000,
                maximumMemberships: Int = 100_000, maximumChaptersPerManga: Int = 20_000,
                maximumAlternateTitles: Int = 256, maximumGenres: Int = 256,
                maximumURLBytes: Int = 4_096, maximumLabelBytes: Int = 1_024,
                maximumMetadataBytes: Int = 8_192, maximumDescriptionBytes: Int = 256 * 1024,
                maximumTotalStringBytes: Int = 32 * 1024 * 1024) throws {
        let supplied = [maximumInputBytes, maximumDepth, maximumJSONValues, maximumJSONStringBytes,
                        maximumJSONObjectKeys, maximumJSONArrayElements,
                        maximumManga, maximumSources, maximumCategories, maximumChapters,
                        maximumHistory, maximumKnownChapters, maximumMemberships,
                        maximumChaptersPerManga, maximumAlternateTitles, maximumGenres,
                        maximumURLBytes, maximumLabelBytes, maximumMetadataBytes,
                        maximumDescriptionBytes, maximumTotalStringBytes]
        let hard = Self.default
        let ceilings = [hard.maximumInputBytes, hard.maximumDepth, hard.maximumJSONValues,
                        hard.maximumJSONStringBytes, hard.maximumJSONObjectKeys,
                        hard.maximumJSONArrayElements, hard.maximumManga, hard.maximumSources,
                        hard.maximumCategories, hard.maximumChapters, hard.maximumHistory,
                        hard.maximumKnownChapters, hard.maximumMemberships,
                        hard.maximumChaptersPerManga, hard.maximumAlternateTitles,
                        hard.maximumGenres, hard.maximumURLBytes, hard.maximumLabelBytes,
                        hard.maximumMetadataBytes, hard.maximumDescriptionBytes,
                        hard.maximumTotalStringBytes]
        guard maximumInputBytes > 0, maximumDepth > 0,
              zip(supplied, ceilings).allSatisfy({ $0.0 >= 0 && $0.0 <= $0.1 }) else {
            throw LibraryBackupError.invalidPolicy
        }
        self.maximumInputBytes = maximumInputBytes
        self.maximumDepth = maximumDepth
        self.maximumJSONValues = maximumJSONValues
        self.maximumJSONStringBytes = maximumJSONStringBytes
        self.maximumJSONObjectKeys = maximumJSONObjectKeys
        self.maximumJSONArrayElements = maximumJSONArrayElements
        self.maximumManga = maximumManga
        self.maximumSources = maximumSources
        self.maximumCategories = maximumCategories
        self.maximumChapters = maximumChapters
        self.maximumHistory = maximumHistory
        self.maximumKnownChapters = maximumKnownChapters
        self.maximumMemberships = maximumMemberships
        self.maximumChaptersPerManga = maximumChaptersPerManga
        self.maximumAlternateTitles = maximumAlternateTitles
        self.maximumGenres = maximumGenres
        self.maximumURLBytes = maximumURLBytes
        self.maximumLabelBytes = maximumLabelBytes
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumDescriptionBytes = maximumDescriptionBytes
        self.maximumTotalStringBytes = maximumTotalStringBytes
    }
}

/// Finite failures deliberately omit archive-controlled keys, URLs and labels.
public enum LibraryBackupError: Error, Sendable, Equatable, LocalizedError {
    public enum Limit: String, Sendable, Equatable {
        case inputBytes, depth, jsonValues, jsonStringBytes, jsonObjectKeys, jsonArrayElements
        case manga, sources, categories
        case chapters, history, knownChapters, memberships, chaptersPerManga
        case alternateTitles, genres, urlBytes, labelBytes, metadataBytes, descriptionBytes
        case totalStringBytes
    }

    case invalidPolicy, invalidJSON, duplicateJSONKey, unknownSchemaKey, invalidSchema
    case unsupportedVersion(Int), invalidEnvelope, invalidDecimalInteger
    case limitExceeded(Limit), duplicateIdentity, danglingReference, ambiguousCategoryName
    case invalidContentBinding

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: return "The library backup limits are invalid."
        case .invalidJSON: return "The library backup is not valid JSON."
        case .duplicateJSONKey: return "The library backup contains a repeated JSON key."
        case .unknownSchemaKey: return "The library backup contains an unsupported field."
        case .invalidSchema: return "The library backup contains invalid stored data."
        case .unsupportedVersion: return "This library backup version is unsupported."
        case .invalidEnvelope: return "This file is not a supported Kami library backup."
        case .invalidDecimalInteger: return "The library backup contains an invalid integer."
        case .limitExceeded: return "The library backup exceeds a supported limit."
        case .duplicateIdentity: return "The library backup contains a repeated identity."
        case .danglingReference: return "The library backup refers to a missing stored row."
        case .ambiguousCategoryName: return "The library backup contains ambiguous category names."
        case .invalidContentBinding: return "The library backup contains an invalid source content binding."
        }
    }
}

// SQLite BINARY identity permits canonically equivalent Unicode spellings.
// DTO equality also preserves exact stored text instead of Swift's normalized
// String equality, so a round-trip assertion cannot mask a spelling change.
private func backupTextEqual(_ first: String, _ second: String) -> Bool {
    first.utf8.elementsEqual(second.utf8)
}

private func backupTextEqual(_ first: String?, _ second: String?) -> Bool {
    switch (first, second) {
    case (nil, nil): return true
    case let (first?, second?): return backupTextEqual(first, second)
    default: return false
    }
}

private func backupTextEqual(_ first: [String], _ second: [String]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy { backupTextEqual($0.0, $0.1) }
}

extension LibraryBackupDocument.ContentBinding {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && backupTextEqual(lhs.deploymentURL, rhs.deploymentURL)
    }
}

extension LibraryBackupDocument.Source {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID && backupTextEqual(lhs.name, rhs.name)
            && backupTextEqual(lhs.language, rhs.language) && backupTextEqual(lhs.packageHint, rhs.packageHint)
            && lhs.contentBinding == rhs.contentBinding
    }
}

extension LibraryBackupDocument.Category {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        backupTextEqual(lhs.key, rhs.key) && backupTextEqual(lhs.name, rhs.name)
            && lhs.sortOrder == rhs.sortOrder && lhs.flags == rhs.flags
    }
}

extension LibraryBackupDocument.Manga {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.sourceID == rhs.sourceID, backupTextEqual(lhs.url, rhs.url),
              backupTextEqual(lhs.title, rhs.title), backupTextEqual(lhs.altTitles, rhs.altTitles),
              backupTextEqual(lhs.thumbnailURL, rhs.thumbnailURL), backupTextEqual(lhs.author, rhs.author),
              backupTextEqual(lhs.artist, rhs.artist), backupTextEqual(lhs.descriptionText, rhs.descriptionText),
              backupTextEqual(lhs.genres, rhs.genres), lhs.status == rhs.status, lhs.inLibrary == rhs.inLibrary,
              lhs.dateAdded == rhs.dateAdded, lhs.dateUpdated == rhs.dateUpdated,
              lhs.lastFetched == rhs.lastFetched, lhs.updateStrategy == rhs.updateStrategy,
              lhs.initialized == rhs.initialized, backupTextEqual(lhs.categoryKeys, rhs.categoryKeys) else { return false }
        return lhs.chapters == rhs.chapters && lhs.history == rhs.history
            && lhs.discoveryBaseline == rhs.discoveryBaseline && lhs.knownChapters == rhs.knownChapters
    }
}

extension LibraryBackupDocument.Chapter {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceOrder == rhs.sourceOrder && backupTextEqual(lhs.url, rhs.url)
            && backupTextEqual(lhs.name, rhs.name) && backupTextEqual(lhs.scanlator, rhs.scanlator)
            && lhs.number == rhs.number && lhs.dateUpload == rhs.dateUpload && lhs.dateFetch == rhs.dateFetch
            && lhs.read == rhs.read && lhs.bookmark == rhs.bookmark && lhs.lastPageRead == rhs.lastPageRead
            && lhs.isCurrent == rhs.isCurrent
    }
}

extension LibraryBackupDocument.History {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        backupTextEqual(lhs.chapterURL, rhs.chapterURL) && lhs.lastRead == rhs.lastRead
            && lhs.readDuration == rhs.readDuration
    }
}

extension LibraryBackupDocument.KnownChapter {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        backupTextEqual(lhs.url, rhs.url) && lhs.firstSeen == rhs.firstSeen && lhs.detectedAt == rhs.detectedAt
    }
}
