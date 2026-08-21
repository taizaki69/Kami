import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MihonCompatKit

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
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
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

        let (data, _) = try await get(comps.url!)
        let resp = try JSONDecoder().decode(MDResponse<MDManga>.self, from: data)
        let total = resp.total ?? 0
        let offset = resp.offset ?? 0
        let mangas = (resp.data ?? []).map(Self.toCompat)
        return MangasPageCompat(mangas: mangas, hasNextPage: offset + mangas.count < total)
    }

    public func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
        var comps = URLComponents(string: "\(api)/manga/\(manga.url)")!
        comps.queryItems = [URLQueryItem(name: "includes[]", value: "cover_art")]
        let (data, _) = try await get(comps.url!)
        let single = try JSONDecoder().decode(SingleManga.self, from: data)
        return Self.toCompat(single.data)

        struct SingleManga: Decodable { let data: MDManga }
    }

    public func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
        // Aggregate endpoint gives ordered, deduplicated chapters.
        let (aggData, _) = try await get(URL(string: "\(api)/manga/\(manga.url)/aggregate?translatedLanguage[]=en")!)
        let agg = try JSONDecoder().decode(MDAggregate.self, from: aggData)

        var chapters: [SChapterCompat] = []
        for (_, volume) in (agg.volumes ?? [:]).sorted(by: { Double($0.key) ?? 0 < Double($1.key) ?? 0 }) {
            for (_, chapter) in (volume.chapters ?? [:]).sorted(by: { Double($0.key) ?? 0 < Double($1.key) ?? 0 }) {
                guard let id = chapter.id else { continue }
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
            let baseUrl: String
            let chapter: Chapter
            struct Chapter: Decodable { let hash: String; let data: [String]; let dataSaver: [String] }
        }
        let (data, _) = try await get(URL(string: "\(api)/at-home/server/\(chapter.url)?forcePort443=false")!)
        let home = try JSONDecoder().decode(AtHome.self, from: data)
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

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Kami/0.1 (iOS manga reader)", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), response!))
                }
            }.resume()
        }
    }
}
