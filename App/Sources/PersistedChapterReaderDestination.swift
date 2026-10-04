import SwiftUI
import KamiCore

/// Resolves the chapter and its neighbours from the current database when
/// the user opens a row. Merely loading History or Updates writes nothing.
@MainActor
struct PersistedChapterReaderDestination: View {
    @EnvironmentObject private var model: AppModel
    let manga: Manga
    let chapterID: Int64
    let chapterURL: String
    var openingPolicy: ReaderOpeningPolicy = .automatic
    @State private var presentation: LibraryPresentationGeneration

    @State private var chapter: Chapter?
    @State private var readingSnapshot: MangaReadingSnapshot?
    @State private var retainedTarget: ChapterWriteTarget?
    @State private var loading = true
    @State private var errorText: String?
    @State private var requiresReopening = false
    @State private var retry = 0
    @State private var loadGeneration: UInt64 = 0
    @State private var resolvedPolicy: ReaderOpeningPolicy = .automatic

    init(manga: Manga, chapterID: Int64, chapterURL: String,
         openingPolicy: ReaderOpeningPolicy = .automatic, presentation: LibraryPresentationGeneration) {
        self.manga = manga
        self.chapterID = chapterID
        self.chapterURL = chapterURL
        self.openingPolicy = openingPolicy
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        ZStack {
            if loading {
                ProgressView("Opening chapter…")
            } else if let chapter, let readingSnapshot {
                ReaderView(snapshot: readingSnapshot, chapter: chapter, openingPolicy: resolvedPolicy,
                           presentation: presentation)
            } else {
                ContentUnavailableView {
                    Label("Chapter unavailable", systemImage: "book.closed")
                } description: {
                    Text(errorText ?? "This chapter is no longer in the source's current chapter list. Your reading history is still saved.")
                } actions: {
                    if !requiresReopening { Button("Retry") { retry &+= 1 } }
                }
            }
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { await model.runLibraryOperation(expected: presentation) { await load() } }
        .onDisappear { loadGeneration &+= 1 }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        errorText = nil
        chapter = nil
        readingSnapshot = nil
        defer { if generation == loadGeneration { loading = false } }
        guard let mangaID = manga.id else { return }
        do {
            await model.waitForReadingSaves()
            guard !Task.isCancelled, generation == loadGeneration else { return }
            let snapshot: MangaReadingSnapshot
            if let retainedTarget {
                snapshot = try await model.store.refreshReadingSnapshot(validating: retainedTarget)
            } else {
                guard let initial = try await model.store.readingSnapshot(
                    sourceID: manga.sourceId, mangaURL: manga.url, requestedChapterID: chapterID
                ) else { throw ReadingStateError.mangaNotFound }
                snapshot = initial
            }
            guard snapshot.manga.id == mangaID,
                  let target = snapshot.target(for: chapterID),
                  Data(target.chapterURL.utf8) == Data(chapterURL.utf8),
                  Data(target.mangaURL.utf8) == Data(manga.url.utf8) else {
                throw ReadingStateError.identityChanged
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            // A retry retains this target even when later download/provider work fails.
            retainedTarget = target
            let states = try await model.store.downloadChapterStates(chapterIDs: [chapterID])
            await model.refreshDownloadAvailability(chapterIDs: [chapterID])
            let current = try await model.store.validateReadingTarget(target)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            readingSnapshot = snapshot
            chapter = current
            resolvedPolicy = openingPolicy == .automatic
                ? (states[chapterID]?.state == .finished ? .offlineOnly : .onlineOnly)
                : openingPolicy
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            requiresReopening = ReadingPresentation.requiresReopening(error)
            errorText = error is ReadingStateError ? ReadingPresentation.message(error)
                : "This chapter could not be opened. Please try again."
        }
    }
}
