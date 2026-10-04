import Foundation
import MihonCompatKit

public enum MangaDexSourceError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The MangaDex request is invalid."
        case .invalidResponse: return "MangaDex returned an incomplete response."
        case let .httpStatus(status): return "MangaDex returned HTTP \(status)."
        }
    }
}

/// Native MangaDex source speaking the public MangaDex API v5 (jsonapi).
/// This is a *native* source — not extension compatibility — and exists so
/// Kami is a usable reader before the DEX runtime matures.
public struct MangaDexSource: KamiSource {
    public let id: Int64 = 2_499_283_573_021_220_255 // matches Mihon's MangaDex source id
    public let name = "MangaDex"
    public let language = "en"
    public let supportsLatest = true
    public let baseURL = "https://mangadex.org"

    private let api = "https://api.mangadex.org"
    static let maximumAPIResponseBytes = 16 * 1024 * 1024
    private static let apiPolicy = CompatHTTPTransportPolicy(
        maximumRequestBodyBytes: 1,
        maximumResponseBodyBytes: maximumAPIResponseBytes,
        allowsInsecureHTTP: false
    )
    private let transport: any CompatHTTPTransport

    public init(transport: (any CompatHTTPTransport)? = nil) {
        self.transport = transport ?? URLSessionCompatHTTPTransport(
            sourceID: "native:mangadex", policy: Self.apiPolicy
        )
    }

    struct MDResponse<T: Decodable>: Decodable {
        let result: String
        let data: [T]?
        let limit: Int?
        let offset: Int?
        let total: Int?
    }

    struct MDManga: Decodable {
        let id: String
        let attributes: MDAttributes
        let relationships: [MDRelationship]?

        struct MDRelationship: Decodable {
            let type: String?
            let attributes: CoverAttrs?
            struct CoverAttrs: Decodable { let fileName: String? }
        }

        struct MDAttributes: Decodable {
            let title: [String: String]?
            let altTitles: [[String: String]]?
            let description: [String: String]?
            let artists: [MDRel]?
            let authors: [MDRel]?
            let tags: [MDTag]?
            let status: String?

            struct MDRel: Decodable { let attributes: Name?; struct Name: Decodable { let name: String? } }
            struct MDTag: Decodable { let attributes: Name?; struct Name: Decodable { let name: [String: String]? } }
        }
    }

    struct MDChapter: Decodable {
        let id: String
        let attributes: Attr

        struct Attr: Decodable {
            let chapter: String?
            let title: String?
            let volume: String?
            let translatedLanguage: String?
            let publishAt: String?
            let readableAt: String?
            let createdAt: String?
        }
    }

    struct MDAggregate: Decodable {
        let result: String?
        let volumes: [String: Vol]?
        struct Vol: Decodable { let chapters: [String: Chap]?
            struct Chap: Decodable { let chapter: String?; let id: String?; let others: [String]? } }
    }

    public func getPopularManga(page: Int) async throws -> MangasPageCompat {
        try await list(page: page, order: ["followedCount": "desc"])
    }

    public func getLatestUpdates(page: Int) async throws -> MangasPageCompat {
        try await list(page: page, order: ["latestUploadedChapter": "desc"])
    }

    public func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
        try await list(page: page, order: ["relevance": "desc"], title: query.isEmpty ? nil : query)
    }

    private func list(page: Int, order: [String: String], title: String? = nil) async throws -> MangasPageCompat {
        guard page > 0, page <= Int.max / 24 else { throw MangaDexSourceError.invalidRequest }
        var comps = URLComponents(string: "\(api)/manga")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "24"),
            URLQueryItem(name: "offset", value: String((page - 1) * 24)),
            URLQueryItem(name: "includes[]", value: "cover_art"),
            URLQueryItem(name: "contentRating[]", value: "safe"),
            URLQueryItem(name: "contentRating[]", value: "suggestive"),
            URLQueryItem(name: "hasAvailableChapters", value: "true"),
        ]
        for (k, v) in order { items.append(URLQueryItem(name: "order[\(k)]", value: v)) }
        if let title { items.append(URLQueryItem(name: "title", value: title)) }
        comps.queryItems = items

        guard let url = comps.url else { throw MangaDexSourceError.invalidRequest }
        let data = try await get(url)
        let resp = try JSONDecoder().decode(MDResponse<MDManga>.self, from: data)
        guard resp.result == "ok", let entries = resp.data else { throw MangaDexSourceError.invalidResponse }
        let total = resp.total ?? 0
        let offset = resp.offset ?? 0
        guard total >= 0, offset >= 0 else { throw MangaDexSourceError.invalidResponse }
        let mangas = entries.map(Self.toCompat)
        return MangasPageCompat(mangas: mangas, hasNextPage: mangas.count < total - min(offset, total))
    }

    public func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
        guard var comps = URLComponents(string: "\(api)/manga/\(manga.url)") else {
            throw MangaDexSourceError.invalidRequest
        }
        comps.queryItems = [URLQueryItem(name: "includes[]", value: "cover_art")]
        guard let url = comps.url else { throw MangaDexSourceError.invalidRequest }
        let data = try await get(url)
        let single = try JSONDecoder().decode(SingleManga.self, from: data)
        guard single.result == nil || single.result == "ok" else { throw MangaDexSourceError.invalidResponse }
        return Self.toCompat(single.data)

        struct SingleManga: Decodable { let result: String?; let data: MDManga }
    }

    public func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
        // Aggregate endpoint gives ordered, deduplicated chapters.
        guard let url = URL(string: "\(api)/manga/\(manga.url)/aggregate?translatedLanguage[]=en") else {
            throw MangaDexSourceError.invalidRequest
        }
        let aggData = try await get(url)
        let agg = try JSONDecoder().decode(MDAggregate.self, from: aggData)
        guard agg.result == nil || agg.result == "ok", let volumes = agg.volumes else {
            throw MangaDexSourceError.invalidResponse
        }

        var chapters: [SChapterCompat] = []
        for (_, volume) in volumes.sorted(by: { Double($0.key) ?? 0 < Double($1.key) ?? 0 }) {
            guard let entries = volume.chapters else { throw MangaDexSourceError.invalidResponse }
            for (_, chapter) in entries.sorted(by: { Double($0.key) ?? 0 < Double($1.key) ?? 0 }) {
                guard let id = chapter.id, !id.isEmpty else { throw MangaDexSourceError.invalidResponse }
                let number = chapter.chapter ?? "?"
                let epoch = Self.parseDate(nil) // date comes from a chapter fetch; keep 0
                chapters.append(SChapterCompat(
                    url: id,
                    name: "Chapter \(number)",
                    number: number,
                    dateUpload: epoch
                ))
            }
        }
        return chapters.reversed() // newest first, matching Mihon's default sort
    }

    public func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] {
        struct AtHome: Decodable {
            let result: String?
            let baseUrl: String
            let chapter: Chapter
            struct Chapter: Decodable { let hash: String; let data: [String]; let dataSaver: [String] }
        }
        guard let url = URL(string: "\(api)/at-home/server/\(chapter.url)?forcePort443=false") else {
            throw MangaDexSourceError.invalidRequest
        }
        let data = try await get(url)
        let home = try JSONDecoder().decode(AtHome.self, from: data)
        guard home.result == nil || home.result == "ok" else { throw MangaDexSourceError.invalidResponse }
        return home.chapter.data.enumerated().map { index, file in
            PageCompat(
                index: index,
                imageURL: "\(home.baseUrl)/data/\(home.chapter.hash)/\(file)"
            )
        }
    }

    public func getFilterList() -> [SourceFilter] { [] }

    private static func toCompat(_ m: MDManga) -> SMangaCompat {
        let attrs = m.attributes
        let title = attrs.title?["en"] ?? attrs.title?.values.first ?? ""
        let alts = (attrs.altTitles ?? []).compactMap { $0["en"] ?? $0.values.first }
        let authors = (attrs.authors ?? []).compactMap(\.attributes?.name).joined(separator: ", ")
        let artists = (attrs.artists ?? []).compactMap(\.attributes?.name).joined(separator: ", ")
        let description = attrs.description?["en"] ?? attrs.description?.values.first
        let tags = (attrs.tags ?? []).compactMap { $0.attributes?.name?["en"] }
        let coverFile = (m.relationships ?? []).first { $0.type == "cover_art" }?.attributes?.fileName
        var compat = SMangaCompat(
            url: m.id,
            title: title,
            altTitles: alts,
            thumbnailURL: coverFile.map { "https://uploads.mangadex.org/covers/\(m.id)/\($0).512.jpg" },
            artist: artists.isEmpty ? nil : artists,
            author: authors.isEmpty ? nil : authors,
            description: description,
            genres: tags
        )
        switch attrs.status {
        case "ongoing": compat.status = .ongoing
        case "completed": compat.status = .completed
        case "hiatus": compat.status = .onHiatus
        case "cancelled": compat.status = .cancelled
        default: compat.status = .unknown
        }
        compat.thumbnailURL = coverFile.map { "https://uploads.mangadex.org/covers/\(m.id)/\($0).512.jpg" }
        compat.initialized = true
        return compat
    }

    static func parseDate(_ s: String?) -> Int64 {
        guard let s else { return 0 }
        let iso = ISO8601DateFormatter()
        return Int64(iso.date(from: s)?.timeIntervalSince1970 ?? 0) * 1000
    }

    private func get(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let request = CompatHTTPRequest(url: url.absoluteString, headers: [
            .init(name: "User-Agent", value: "Kami/0.1 (iOS manga reader)")
        ])
        try Self.apiPolicy.validate(request: request)
        let response = try await transport.execute(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            throw MangaDexSourceError.httpStatus(response.statusCode)
        }
        // The production transport enforces this while streaming; checking the
        // injected seam also keeps a late/oversized fixture from reaching JSON.
        guard response.body.count <= Self.maximumAPIResponseBytes else {
            throw CompatHTTPTransportError.responseBodyTooLarge(limit: Self.maximumAPIResponseBytes)
        }
        return Data(response.body)
    }
}
