import SwiftUI
import KamiCore

/// Resolves the chapter and its neighbours from the current database when
/// the user opens a row. Merely loading History or Updates writes nothing.
@MainActor
struct PersistedChapterReaderDestination: View {
    @EnvironmentObject private var model: AppModel
    let manga: Manga
    let chapterID: Int64

    @State private var chapter: Chapter?
    @State private var neighbours: [Chapter] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var retry = 0
    @State private var loadGeneration: UInt64 = 0

    var body: some View {
        ZStack {
            if model.source(id: manga.sourceId) == nil {
                ContentUnavailableView("Source unavailable", systemImage: "pause.circle",
                    description: Text("Your reading data is saved. Enable this source in Extensions to continue reading."))
            } else if loading {
                ProgressView("Opening chapter…")
            } else if let chapter {
                ReaderView(mangaTitle: manga.title, chapter: chapter,
                           chapters: neighbours, sourceID: manga.sourceId)
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
        .task(id: "\(model.sourceRevision(for: manga.sourceId)):\(retry)") { await load() }
        .onDisappear { loadGeneration &+= 1 }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let revision = model.sourceRevision(for: manga.sourceId)
        loading = true
        errorText = nil
        chapter = nil
        neighbours = []
        defer { if generation == loadGeneration { loading = false } }
        guard let mangaID = manga.id, model.source(id: manga.sourceId) != nil else { return }
        do {
            let current = try await model.store.chapters(mangaId: mangaID)
            guard !Task.isCancelled, generation == loadGeneration,
                  model.isSourceCurrent(id: manga.sourceId, revision: revision) else { return }
            neighbours = current
            chapter = current.first { $0.id == chapterID && $0.mangaId == mangaID }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  model.isSourceCurrent(id: manga.sourceId, revision: revision) else { return }
            errorText = "This chapter could not be opened. Please try again."
        }
    }
}
