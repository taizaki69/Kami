import Foundation
import MihonCompatKit

/// App-domain models. `Manga`/`Chapter` are the persisted forms; converting
/// from `SMangaCompat`/`SChapterCompat` happens at the source boundary.

public struct Manga: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sourceId: Int64
    public var url: String
    public var title: String
    public var altTitles: [String]
    public var thumbnailURL: String?
    public var author: String?
    public var artist: String?
    public var descriptionText: String?
    public var genres: [String]
    public var status: MangaStatus
    public var inLibrary: Bool
    public var dateAdded: Int64
    public var dateUpdated: Int64
    public var updateStrategy: UpdateStrategy

    public init(
        id: Int64? = nil,
        sourceId: Int64,
        url: String,
        title: String = "",
        altTitles: [String] = [],
        thumbnailURL: String? = nil,
        author: String? = nil,
        artist: String? = nil,
        descriptionText: String? = nil,
        genres: [String] = [],
        status: MangaStatus = .unknown,
        inLibrary: Bool = false,
        dateAdded: Int64 = 0,
        dateUpdated: Int64 = 0,
        updateStrategy: UpdateStrategy = .alwaysUpdate
    ) {
        self.id = id
        self.sourceId = sourceId
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
        self.updateStrategy = updateStrategy
    }

    public init(sourceId: Int64, from compat: SMangaCompat) {
        self.init(
            sourceId: sourceId,
            url: compat.url,
            title: compat.title,
            altTitles: compat.altTitles,
            thumbnailURL: compat.thumbnailURL,
            author: compat.author,
            artist: compat.artist,
            descriptionText: compat.description,
            genres: compat.genres,
            status: compat.status,
            updateStrategy: compat.updateStrategy
        )
    }
}

public struct Chapter: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var mangaId: Int64
    public var sourceOrder: Int
    public var url: String
    public var name: String
    public var scanlator: String?
    public var number: Double
    public var dateUpload: Int64
    public var read: Bool
    public var bookmark: Bool
    public var lastPageRead: Int

    public init(
        id: Int64? = nil,
        mangaId: Int64 = 0,
        sourceOrder: Int = 0,
        url: String,
        name: String,
        scanlator: String? = nil,
        number: Double = -1,
        dateUpload: Int64 = 0,
        read: Bool = false,
        bookmark: Bool = false,
        lastPageRead: Int = 0
    ) {
        self.id = id
        self.mangaId = mangaId
        self.sourceOrder = sourceOrder
        self.url = url
        self.name = name
        self.scanlator = scanlator
        self.number = number
        self.dateUpload = dateUpload
        self.read = read
        self.bookmark = bookmark
        self.lastPageRead = lastPageRead
    }

    public init(mangaId: Int64, sourceOrder: Int, from compat: SChapterCompat) {
        self.init(
            mangaId: mangaId,
            sourceOrder: sourceOrder,
            url: compat.url,
            name: compat.name,
            scanlator: compat.scanlators.first,
            number: Double(compat.number ?? "") ?? Double(compat.chapterNumber),
            dateUpload: compat.dateUpload
        )
    }
}

public struct Category: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var order: Int

    public init(id: Int64? = nil, name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public struct HistoryEntry: Hashable, Sendable {
    public var mangaId: Int64
    public var chapterId: Int64
    public var lastRead: Int64

    public init(mangaId: Int64, chapterId: Int64, lastRead: Int64) {
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.lastRead = lastRead
    }
}

public enum DownloadState: Int, Codable, Sendable {
    case queued = 0, downloading = 1, finished = 2, failed = 3
}
