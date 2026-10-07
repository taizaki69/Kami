import SwiftUI
import MihonCompatKit
import KamiCore

@MainActor
struct MangaDetailView: View {
    @EnvironmentObject var model: AppModel

    let manga: Manga
    var prefetched: SMangaCompat?
    var prefetchedSourceRevision: UInt64?
    @State private var presentation: LibraryPresentationGeneration

    @State private var detail: SMangaCompat?
    @State private var chapters: [Chapter] = []
    @State private var readingSnapshot: MangaReadingSnapshot?
    @State private var readBusyChapters = Set<Int64>()
    @State private var readingError: String?
    @State private var inLibrary = false
    @State private var loading = true
    @State private var errorText: String?
    @State private var libraryBusy = false
    @State private var libraryError: String?
    @State private var categoryAssignment: CategoryAssignmentRequest?
    @State private var loadGeneration = 0
    @State private var loadedSourceRevision: UInt64?
    @State private var showDownloads = false

    init(manga: Manga, prefetched: SMangaCompat? = nil, prefetchedSourceRevision: UInt64? = nil,
         presentation: LibraryPresentationGeneration) {
        self.manga = manga
        self.prefetched = prefetched
        self.prefetchedSourceRevision = prefetchedSourceRevision
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        let snapshot = readingSnapshot
        let savedInLibrary = inLibrary
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Reload manga") {
                        model.performLibraryOperation(expected: presentation) { await load() }
                    }.disabled(loading)
                }
            }
            if let detail {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        CoverImage(url: detail.thumbnailURL, cornerRadius: 8)
                            .frame(width: 100, height: 145)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail.title).font(.headline)
                            if let author = detail.author {
                                Label(author, systemImage: "person")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Label(statusText, systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button {
                                toggleLibrary(snapshot: snapshot, adding: !savedInLibrary)
                            } label: {
                                Label(savedInLibrary ? "In library" : "Add to library",
                                      systemImage: savedInLibrary ? "checkmark.circle.fill" : "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(libraryBusy || snapshot?.manga.id == nil)
                            if savedInLibrary, let id = snapshot?.manga.id {
                                Button {
                                    categoryAssignment = CategoryAssignmentRequest(mangaIDs: [id],
                                        title: detail.title, context: snapshot?.mutationContext)
                                } label: {
                                    Label(categoryLabel(mangaId: id), systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(libraryBusy)
                            }
                        }
                    }
                    if let description = detail.description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !detail.genres.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(detail.genres, id: \.self) { genre in
                                    Text(genre)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                }
            } else if loading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }

            Section("Chapters") {
                ForEach(chapters) { chapter in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            if let snapshot {
                                ReaderView(snapshot: snapshot, chapter: chapter,
                                           openingPolicy: isDownloaded(chapter) ? .offlineOnly : .automatic,
                                           presentation: presentation)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.name)
                                    if let scanlator = chapter.scanlator {
                                        Text(scanlator).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Label(isDownloaded(chapter) ? "Read offline" : "Read online",
                                          systemImage: isDownloaded(chapter) ? "arrow.down.circle.fill" : "book")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chapter.read {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green).accessibilityLabel("Read")
                                }
                            }
                        }
                        .disabled(snapshot?.target(for: chapter) == nil
                                  || (!hasCurrentSource && !isDownloaded(chapter)))
                        ChapterDownloadControls(manga: manga, chapter: chapter, inLibrary: inLibrary,
                                                presentation: presentation)
                    }
                    .swipeActions {
                        Button(chapter.read ? "Unread" : "Read") {
                            markRead(chapter)
                        }
                        .tint(.blue)
                        .disabled(chapter.id.map(readBusyChapters.contains) ?? true)
                    }
                }
            }
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inLibrary, let snapshot = readingSnapshot {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SourceMigrationView(origin: snapshot, title: detail?.title ?? manga.title, presentation: presentation)
                    } label: {
                        Label("Migrate to another source", systemImage: "arrow.triangle.swap")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDownloads = true } label: { Label("Downloads", systemImage: "arrow.down.circle") }
            }
        }
        .task(id: model.sourceRevision(for: manga.sourceId)) {
            await model.runLibraryOperation(expected: presentation) { await load() }
        }
        .refreshable { await model.runLibraryOperation(expected: presentation) { await load() } }
        .onDisappear { loadGeneration &+= 1 }
        .sheet(item: $categoryAssignment) { request in
            CategoryAssignmentSheet(mangaIDs: request.mangaIDs, title: request.title, context: request.context)
        }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .alert("Could not update library", isPresented: Binding(
            get: { libraryError != nil },
            set: { if !$0 { libraryError = nil } }
        )) {
            Button("OK", role: .cancel) { libraryError = nil }
        } message: {
            Text(libraryError ?? "")
        }
        .alert("Could not save reading state", isPresented: Binding(
            get: { readingError != nil },
            set: { if !$0 { readingError = nil } }
        )) {
            Button("OK", role: .cancel) { readingError = nil }
        } message: {
            Text(readingError ?? "")
        }
    }

    private var hasCurrentSource: Bool {
        loadedSourceRevision == model.sourceRevision(for: manga.sourceId)
            && model.source(id: manga.sourceId) != nil
    }

    private func isDownloaded(_ chapter: Chapter) -> Bool {
        chapter.id.map { model.isChapterDownloaded($0) } ?? false
    }

    private var statusText: String {
        switch detail?.status ?? .unknown {
        case .ongoing: return "Ongoing"
        case .completed: return "Completed"
        case .licensed: return "Licensed"
        case .publishingFinished: return "Publishing finished"
        case .cancelled: return "Cancelled"
        case .onHiatus: return "On hiatus"
        case .unknown: return "Unknown status"
        }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let revision = model.sourceRevision(for: manga.sourceId)
        loading = true
        errorText = nil
        loadedSourceRevision = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            await model.waitForReadingSaves()
            guard !Task.isCancelled, generation == loadGeneration else { return }
            let sourceSnapshot = try await model.store.sourceMangaSnapshot(sourceID: manga.sourceId, mangaURL: manga.url)
            let initial = sourceSnapshot.reading
            let mutationContext = sourceSnapshot.mutationContext
            let existing = initial?.manga
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if let initial, let existing, let id = existing.id {
                await model.refreshDownloadAvailability(mangaID: id)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                detail = savedDetail(existing)
                inLibrary = existing.inLibrary
                readingSnapshot = initial
                chapters = initial.readerChapters
                loadedSourceRevision = model.isSourceCurrent(id: manga.sourceId, revision: revision) ? revision : nil
            }
            guard let source = model.source(id: manga.sourceId) else {
                errorText = "Source unavailable. Downloaded chapters can still be read offline. Enable this source in Extensions to refresh or download."
                return
            }
            let execution = try model.sourceExecutionConfiguration(id: manga.sourceId, revision: revision)
            try await model.store.validateSourceExecution(sourceID: manga.sourceId, expectedConfiguration: execution,
                                                           context: mutationContext)
            guard canPublish(revision: revision, generation: generation) else { return }

            var compat = prefetchedSourceRevision == revision
                ? prefetched ?? SMangaCompat(url: manga.url, title: manga.title)
                : SMangaCompat(url: manga.url, title: manga.title)
            if !compat.initialized {
                compat = try await source.getMangaDetails(manga: compat)
            }
            guard canPublish(revision: revision, generation: generation) else { return }
            let chapterList = try await source.getChapterList(manga: compat)
            guard canPublish(revision: revision, generation: generation) else { return }

            // Core checks the captured execution/configuration token inside
            // the same transaction that writes manga and chapters. UI checks
            // alone cannot close a race with a concurrent source-URL save.
            var persisted = Manga(sourceId: manga.sourceId, from: compat)
            persisted.id = existing?.id
            persisted.inLibrary = existing?.inLibrary ?? manga.inLibrary
            persisted.dateAdded = existing?.dateAdded ?? manga.dateAdded
            persisted.dateUpdated = Int64(Date().timeIntervalSince1970)
            let saved = try await model.store.persistSourceUpdate(
                manga: persisted,
                chapters: chapterList,
                expectedConfiguration: execution, context: mutationContext
            )
            guard canPublish(revision: revision, generation: generation) else { return }
            guard let savedID = saved.manga.id else { throw DownloadPersistenceError.chapterNotFound }
            let current = try await model.store.sourceMangaSnapshot(
                sourceID: manga.sourceId, mangaURL: manga.url, validating: mutationContext)
            guard let savedReading = current.reading else { throw ReadingStateError.mangaNotFound }
            await model.refreshDownloadAvailability(mangaID: savedID)
            guard canPublish(revision: revision, generation: generation) else { return }
            inLibrary = savedReading.manga.inLibrary
            detail = savedDetail(savedReading.manga)
            readingSnapshot = savedReading
            chapters = savedReading.readerChapters
            loadedSourceRevision = revision
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorText = (error as? LibraryMutationError)?.errorDescription
                ?? "This manga could not be refreshed. Saved chapters and downloads remain available. Please try again when the source is available."
        }
    }

    private func savedDetail(_ manga: Manga) -> SMangaCompat {
        SMangaCompat(url: manga.url, title: manga.title, altTitles: manga.altTitles,
            thumbnailURL: manga.thumbnailURL, artist: manga.artist, author: manga.author,
            status: manga.status, description: manga.descriptionText, genres: manga.genres,
            updateStrategy: manga.updateStrategy, initialized: true)
    }

    private func canPublish(revision: UInt64, generation: Int) -> Bool {
        !Task.isCancelled && generation == loadGeneration
            && model.isSourceCurrent(id: manga.sourceId, revision: revision)
    }

    private func toggleLibrary(snapshot: MangaReadingSnapshot?, adding: Bool) {
        guard let snapshot, let id = snapshot.manga.id, !libraryBusy else { return }
        let context = snapshot.mutationContext
        libraryBusy = true
        let worker = model.performLibraryOperation(expected: presentation) {
            defer { libraryBusy = false }
            do {
                try await model.setLibrary(adding, mangaId: id, context: context)
                inLibrary = adding
                if adding, !model.categories.isEmpty {
                    categoryAssignment = CategoryAssignmentRequest(mangaIDs: [id],
                        title: detail?.title ?? manga.title, context: context)
                }
            } catch {
                libraryError = model.libraryErrorMessage(for: error)
            }
        }
        if worker == nil { libraryBusy = false }
    }

    private func categoryLabel(mangaId: Int64) -> String {
        let ids = model.librarySnapshot.categoryIDsByManga[mangaId] ?? []
        let names = model.categories.filter { $0.id.map(ids.contains) ?? false }.map(\.name)
        return names.isEmpty ? "Set categories" : names.joined(separator: ", ")
    }

    private func markRead(_ chapter: Chapter) {
        guard let id = chapter.id, !readBusyChapters.contains(id),
              let target = readingSnapshot?.target(for: chapter) else { return }
        let read = !chapter.read
        let generation = loadGeneration
        readBusyChapters.insert(id)
        let receipt = model.readingStateWriter.enqueueRead(read, target: target)
        Task {
            defer { readBusyChapters.remove(id) }
            do {
                let saved = try await receipt.value()
                guard !Task.isCancelled, generation == loadGeneration,
                      readingSnapshot?.target(for: id) == target,
                      let index = chapters.firstIndex(where: { $0.id == id }) else { return }
                chapters[index] = saved
            } catch is CancellationError {
                return
            } catch {
                guard generation == loadGeneration else { return }
                readingError = ReadingPresentation.message(error)
            }
        }
    }
}
