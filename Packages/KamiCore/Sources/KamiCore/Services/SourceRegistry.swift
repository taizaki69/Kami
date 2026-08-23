import Foundation
import MihonCompatKit

/// Registry of all installed/available sources. Native and interpreted sources
/// share `KamiSource`, so the app layer does not need source-kind branches.
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

    /// Registers a compiled, exact-hash pinned adapter. The concrete type
    /// prevents this path from accepting an arbitrary downloaded source.
    public func addPinned(_ source: PinnedInterpretedSource) {
        addTrusted(source)
    }

    /// The only public registration path for a source constructed from a
    /// downloaded APK. The capability is issued after signer trust is
    /// persisted, and the source ID must have been declared by that extension.
    public func addDownloaded(
        _ source: any KamiSource,
        admission: ExtensionAdmission
    ) throws {
        guard admission.sourceIDs.contains(source.id) else {
            throw ExtensionAdmissionError.sourceNotDeclared(source.id)
        }
        addTrusted(source)
    }

    private func addTrusted(_ source: any KamiSource) {
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
        let update = try await source.getMangaUpdate(manga: compat)
        let chapters = update.chapters
        compat = update.manga
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
