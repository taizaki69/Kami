import Foundation
import MihonCompatKit

/// Registry of all installed/available sources. Today: native sources only.
/// The DEX compatibility runtime will register bridged sources here without
/// the app layer knowing the difference.
@MainActor
public final class SourceRegistry {
    public private(set) var sources: [any KamiSource] = []

    public init() {
        registerDefaults()
    }

    func registerDefaults() {
        let md = MangaDexSource()
        sources.append(md)
    }

    public func source(id: Int64) -> (any KamiSource)? {
        sources.first { $0.id == id }
    }

    public func add(_ source: any KamiSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        sources.append(source)
    }
}

#if canImport(SQLite3)
/// Library-facing service: search/browse coordination and manga metadata
/// refresh, talking to sources and persisting via LibraryStore.
public struct LibraryService {
    let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    /// Fetches details+chapters from a source and persists them, preserving
    /// read state. Returns the updated stored manga.
    public func refresh(mangaId: Int64, source: any KamiSource) async throws -> Manga? {
        guard var stored = try await store.manga(id: mangaId) else { return nil }
        var compat = SMangaCompat(
            url: stored.url,
            title: stored.title,
            altTitles: stored.altTitles,
            thumbnailURL: stored.thumbnailURL,
            artist: stored.artist,
            author: stored.author,
            status: stored.status,
            description: stored.descriptionText,
            genres: stored.genres
        )
        let details = try await source.getMangaDetails(manga: compat)
        let chapters = try await source.getChapterList(manga: details)
        compat = details
        compat.initialized = true

        stored.title = compat.title
        stored.thumbnailURL = compat.thumbnailURL
        stored.author = compat.author
        stored.artist = compat.artist
        stored.descriptionText = compat.description
        stored.genres = compat.genres
        stored.status = compat.status
        stored.dateUpdated = Int64(Date().timeIntervalSince1970)
        try await store.upsert(stored)

        let domainChapters = chapters.enumerated().map { order, c in
            Chapter(mangaId: mangaId, sourceOrder: order, from: c)
        }
        try await store.replaceChapters(mangaId: mangaId, with: domainChapters)
        return stored
    }
}
#endif
