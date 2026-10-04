import SwiftUI
import KamiCore

/// Resolves the chapter and its neighbours from the current database when
/// the user opens a row. Merely loading History or Updates writes nothing.
@MainActor
struct PersistedChapterReaderDestination: View {
    @EnvironmentObject private var model: AppModel
    let manga: Manga
    let chapterID: Int64
    var openingPolicy: ReaderOpeningPolicy = .automatic

    @State private var chapter: Chapter?
    @State private var neighbours: [Chapter] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var retry = 0
    @State private var loadGeneration: UInt64 = 0
    @State private var resolvedPolicy: ReaderOpeningPolicy = .automatic

    var body: some View {
        ZStack {
            if loading {
                ProgressView("Opening chapter…")
            } else if let chapter {
                ReaderView(mangaTitle: manga.title, chapter: chapter,
                           chapters: neighbours, sourceID: manga.sourceId, openingPolicy: resolvedPolicy)
            } else {
                ContentUnavailableView {
                    Label("Chapter unavailable", systemImage: "book.closed")
                } description: {
                    Text(errorText ?? "This chapter is no longer in the source's current chapter list. Your reading history is still saved.")
                } actions: {
                    Button("Retry") { retry &+= 1 }
                }
            }
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { await load() }
        .onDisappear { loadGeneration &+= 1 }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        errorText = nil
        chapter = nil
        neighbours = []
        defer { if generation == loadGeneration { loading = false } }
        guard let mangaID = manga.id else { return }
        do {
            let target = try await model.store.downloadTarget(chapterID: chapterID)
            guard target.manga.id == mangaID, target.manga.sourceId == manga.sourceId,
                  target.manga.url == manga.url else {
                errorText = "This chapter no longer matches this manga. Your reading history is still saved."
                return
            }
            let current = try await model.store.chapters(mangaId: mangaID)
            let downloaded = try await model.store.downloadedChapters(mangaID: mangaID)
            let states = try await model.store.downloadChapterStates(chapterIDs: [chapterID])
            await model.refreshDownloadAvailability(chapterIDs: [chapterID])
            guard !Task.isCancelled, generation == loadGeneration else { return }
            var seen = Set(current.compactMap(\.id))
            neighbours = (current + downloaded.filter { item in
                guard let id = item.id else { return false }
                return seen.insert(id).inserted
            }).sorted {
                $0.sourceOrder == $1.sourceOrder ? ($0.id ?? 0) < ($1.id ?? 0) : $0.sourceOrder < $1.sourceOrder
            }
            chapter = target.chapter
            resolvedPolicy = openingPolicy == .automatic
                ? (states[chapterID]?.state == .finished ? .offlineOnly : .onlineOnly)
                : openingPolicy
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorText = "This chapter could not be opened. Please try again."
        }
    }
}
