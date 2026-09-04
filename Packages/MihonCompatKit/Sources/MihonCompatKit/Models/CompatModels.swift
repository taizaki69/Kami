import Foundation

/// Swift-side mirrors of the tachiyomix extension models. These are what the
/// app and (eventually) the DEX runtime exchange with sources; field-by-field
/// fidelity with the Kotlin API is intentional, including legacy fields, so
/// extension behavior maps 1:1. See docs/EXTENSION_COMPATIBILITY_ANALYSIS.md §2.3.

public enum MangaStatus: Int, Codable, Sendable {
    case unknown = 0, ongoing = 1, completed = 2, licensed = 3
    case publishingFinished = 4, cancelled = 5, onHiatus = 6
}

public enum ContentRating: String, Codable, Sendable {
    case safe, suggestive, adult
}

public enum ReadingMode: String, Codable, Sendable {
    case rightToLeft = "RIGHT_TO_LEFT"
    case leftToRight = "LEFT_TO_RIGHT"
    case longStrip = "LONG_STRIP"
}

public enum UpdateStrategy: String, Codable, Sendable {
    case alwaysUpdate = "ALWAYS_UPDATE"
    case onlyFetchOnce = "ONLY_FETCH_ONCE"
}

public struct SMangaCompat: Sendable {
    public var url: String
    public var title: String
    public var altTitles: [String]
    public var thumbnailURL: String?
    public var banner: String?
    public var artist: String?
    public var author: String?
    public var status: MangaStatus
    public var language: String?
    public var contentRating: ContentRating
    public var score: Int?
    public var description: String?
    public var genres: [String]
    public var readingMode: ReadingMode?
    public var updateStrategy: UpdateStrategy
    public var memo: [String: String]   // JsonObject memo, string-typed subset
    public var initialized: Bool

    public init(
        url: String = "",
        title: String = "",
        altTitles: [String] = [],
        thumbnailURL: String? = nil,
        banner: String? = nil,
        artist: String? = nil,
        author: String? = nil,
        status: MangaStatus = .unknown,
        language: String? = nil,
        contentRating: ContentRating = .safe,
        score: Int? = nil,
        description: String? = nil,
        genres: [String] = [],
        readingMode: ReadingMode? = nil,
        updateStrategy: UpdateStrategy = .alwaysUpdate,
        memo: [String: String] = [:],
        initialized: Bool = false
    ) {
        self.url = url
        self.title = title
        self.altTitles = altTitles
        self.thumbnailURL = thumbnailURL
        self.banner = banner
        self.artist = artist
        self.author = author
        self.status = status
        self.language = language
        self.contentRating = contentRating
        self.score = score
        self.description = description
        self.genres = genres
        self.readingMode = readingMode
        self.updateStrategy = updateStrategy
        self.memo = memo
        self.initialized = initialized
    }
}

public struct SChapterCompat: Sendable {
    public var url: String
    public var name: String
    public var volume: String?
    public var chapterNumber: Float
    public var number: String?
    public var scanlators: [String]
    public var dateUpload: Int64
    public var language: String?
    public var locked: Bool
    public var note: String?
    public var memo: [String: String]

    public init(
        url: String = "",
        name: String = "",
        volume: String? = nil,
        chapterNumber: Float = -1,
        number: String? = nil,
        scanlators: [String] = [],
        dateUpload: Int64 = 0,
        language: String? = nil,
        locked: Bool = false,
        note: String? = nil,
        memo: [String: String] = [:]
    ) {
        self.url = url
        self.name = name
        self.volume = volume
        self.chapterNumber = chapterNumber
        self.number = number
        self.scanlators = scanlators
        self.dateUpload = dateUpload
        self.language = language
        self.locked = locked
        self.note = note
        self.memo = memo
    }
}

public struct SMangaUpdateCompat: Sendable {
    public var manga: SMangaCompat
    public var chapters: [SChapterCompat]

    public init(manga: SMangaCompat, chapters: [SChapterCompat]) {
        self.manga = manga
        self.chapters = chapters
    }
}

public struct PageCompat: Sendable {
    public var index: Int
    public var url: String
    public var imageURL: String?

    public init(index: Int, url: String = "", imageURL: String? = nil) {
        self.index = index
        self.url = url
        self.imageURL = imageURL
    }
}

public struct MangasPageCompat: Sendable {
    public var mangas: [SMangaCompat]
    public var hasNextPage: Bool

    public init(mangas: [SMangaCompat], hasNextPage: Bool) {
        self.mangas = mangas
        self.hasNextPage = hasNextPage
    }
}

/// Dynamic source filters, mirroring the sealed `Filter` hierarchy. The UI
/// renders these generically; mutated state flows back into the same values
/// before a search.
public enum SourceFilter: Sendable {
    case header(String)
    case separator(String)
    case select(name: String, values: [String], state: Int)
    case text(name: String, state: String)
    case checkBox(name: String, state: Bool)
    case triState(name: String, state: TriState)
    case group(name: String, filters: [SourceFilter])
    case sort(name: String, values: [String], state: SortSelection?)

    public enum TriState: Int, Sendable, Hashable {
        case ignore = 0, include = 1, exclude = 2
    }

    public struct SortSelection: Sendable {
        public var index: Int
        public var ascending: Bool
        public init(index: Int, ascending: Bool) {
            self.index = index
            self.ascending = ascending
        }
    }

    public var name: String {
        switch self {
        case let .header(n), let .separator(n), let .select(n, _, _),
             let .text(n, _), let .checkBox(n, _), let .triState(n, _),
             let .group(n, _), let .sort(n, _, _):
            return n
        }
    }
}

/// The app-facing source abstraction: what every source kind (native Swift,
/// future DEX-backed) exposes. Native sources implement this directly; the
/// compatibility runtime will bridge tachiyomix classes onto it.
public protocol KamiSource: Sendable {
    var id: Int64 { get }
    var name: String { get }
    var language: String { get }
    var supportsLatest: Bool { get }
    var supportsFilterFetching: Bool { get }
    var baseURL: String { get }
    /// Network policy used by both source operations and reader image loads.
    /// Implementations should opt into insecure HTTP only deliberately.
    var transportPolicy: CompatHTTPTransportPolicy { get }

    func getPopularManga(page: Int) async throws -> MangasPageCompat
    func getLatestUpdates(page: Int) async throws -> MangasPageCompat
    func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat
    func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat
    func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat]
    func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat
    func getPageList(chapter: SChapterCompat) async throws -> [PageCompat]
    func getImageRequest(page: PageCompat) async -> ImageRequest?
    func getFilterList() -> [SourceFilter]
    /// Refreshes source-provided filter metadata when it is network-backed.
    /// Static sources inherit the immediate `getFilterList()` implementation.
    func refreshFilterList() async throws -> [SourceFilter]
}

/// An opaque source-owned execution capability for reader image requests.
/// The closures are immutable and `@Sendable`; interpreted sources use the
/// release hook to discard their actor-isolated DEX request handle when every
/// copy of the public `ImageRequest` has gone away.
final class SourceImageExecution: @unchecked Sendable {
    let id: UUID
    private let operation: @Sendable () async throws -> CompatHTTPResponse
    private let release: @Sendable () -> Void

    init(
        id: UUID,
        operation: @escaping @Sendable () async throws -> CompatHTTPResponse,
        release: @escaping @Sendable () -> Void = {}
    ) {
        self.id = id
        self.operation = operation
        self.release = release
    }

    func execute() async throws -> CompatHTTPResponse {
        try await operation()
    }

    deinit {
        release()
    }
}

/// OkHttp-style image request that the reader must honor. Native sources use
/// URL + headers directly. Interpreted sources may additionally attach an
/// opaque source-scoped executor so the exact OkHttp Request, tags, client,
/// cookies, and supported interceptors survive the app-facing boundary.
public struct ImageRequest: Sendable {
    public let url: String
    public let headers: [String: String]
    private let sourceExecution: SourceImageExecution?

    public init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
        sourceExecution = nil
    }

    /// Trusted Swift sources can provide their own source-scoped execution
    /// path. The UUID is part of reader cache identity, so callers must reuse
    /// it only when two requests have identical hidden execution semantics.
    public init(
        url: String,
        headers: [String: String] = [:],
        sourceExecutionID: UUID,
        sourceExecutor: @escaping @Sendable () async throws -> CompatHTTPResponse
    ) {
        self.url = url
        self.headers = headers
        sourceExecution = SourceImageExecution(
            id: sourceExecutionID,
            operation: sourceExecutor
        )
    }

    init(
        url: String,
        headers: [String: String],
        sourceExecution: SourceImageExecution
    ) {
        self.url = url
        self.headers = headers
        self.sourceExecution = sourceExecution
    }

    /// Non-nil only when this request must not be coalesced with a plain
    /// URL/header load or another source runtime's hidden request state.
    public var sourceExecutionID: UUID? {
        sourceExecution?.id
    }

    /// Returns nil for ordinary native requests. ReaderImagePipeline validates
    /// the public URL/header projection before invoking this capability.
    public func executeSourceRequest() async throws -> CompatHTTPResponse? {
        guard let sourceExecution else { return nil }
        return try await sourceExecution.execute()
    }
}

/// Source-scoped scalar preferences exposed to measured interpreted profiles.
/// The bridge never reads process-global state, and exact profiles decide which
/// keys and values they accept before DEX construction begins.
public struct InterpretedExtensionPreferences: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable {
        case tooManyValues
        case invalidKey
        case duplicateKey
        case stringValueTooLarge
    }

    let strings: [String: String]
    let booleans: [String: Bool]

    public init() {
        strings = [:]
        booleans = [:]
    }

    public init(
        strings: [String: String] = [:],
        booleans: [String: Bool] = [:]
    ) throws {
        guard strings.count + booleans.count <= 64 else {
            throw ValidationError.tooManyValues
        }
        let keys = Array(strings.keys) + Array(booleans.keys)
        guard keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw ValidationError.invalidKey
        }
        guard Set(strings.keys).isDisjoint(with: booleans.keys) else {
            throw ValidationError.duplicateKey
        }
        guard strings.values.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw ValidationError.stringValueTooLarge
        }
        self.strings = strings
        self.booleans = booleans
    }

    var isEmpty: Bool { strings.isEmpty && booleans.isEmpty }
}

public extension KamiSource {
    var supportsLatest: Bool { false }
    var supportsFilterFetching: Bool { false }
    var transportPolicy: CompatHTTPTransportPolicy {
        CompatHTTPTransportPolicy(allowsInsecureHTTP: false)
    }
    func getLatestUpdates(page: Int) async throws -> MangasPageCompat {
        MangasPageCompat(mangas: [], hasNextPage: false)
    }
    func getFilterList() -> [SourceFilter] { [] }
    func refreshFilterList() async throws -> [SourceFilter] { getFilterList() }
    func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
        let details = try await getMangaDetails(manga: manga)
        let chapters = try await getChapterList(manga: details)
        return SMangaUpdateCompat(manga: details, chapters: chapters)
    }
    func getImageRequest(page: PageCompat) async -> ImageRequest? {
        guard let url = page.imageURL else { return nil }
        return ImageRequest(url: url)
    }
}
