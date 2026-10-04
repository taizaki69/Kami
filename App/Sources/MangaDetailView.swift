import SwiftUI
import MihonCompatKit
import KamiCore

@MainActor
struct MangaDetailView: View {
    @EnvironmentObject var model: AppModel

    let manga: Manga
    var prefetched: SMangaCompat?
    var prefetchedSourceRevision: UInt64?

    @State private var detail: SMangaCompat?
    @State private var chapters: [Chapter] = []
    @State private var inLibrary = false
    @State private var loading = true
    @State private var errorText: String?
    @State private var storedId: Int64?
    @State private var libraryBusy = false
    @State private var libraryError: String?
    @State private var categoryAssignment: CategoryAssignmentRequest?
    @State private var loadGeneration = 0
    @State private var loadedSourceRevision: UInt64?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
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
                                toggleLibrary()
                            } label: {
                                Label(inLibrary ? "In library" : "Add to library",
                                      systemImage: inLibrary ? "checkmark.circle.fill" : "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(libraryBusy || storedId == nil)
                            if inLibrary, let id = storedId {
                                Button {
                                    categoryAssignment = CategoryAssignmentRequest(mangaIDs: [id],
                                                                                   title: detail.title)
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
                    NavigationLink {
                        ReaderView(mangaTitle: detail?.title ?? manga.title,
                                   chapter: chapter,
                                   chapters: chapters,
                                   sourceID: manga.sourceId)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.name)
                                if let scanlator = chapter.scanlator {
                                    Text(scanlator).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if chapter.read {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(!hasCurrentSource)
                    .swipeActions {
                        Button(chapter.read ? "Unread" : "Read") {
                            markRead(chapter)
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.sourceRevision(for: manga.sourceId)) { await load() }
        .onDisappear { loadGeneration &+= 1 }
        .sheet(item: $categoryAssignment) { request in
            CategoryAssignmentSheet(mangaIDs: request.mangaIDs, title: request.title)
        }
        .alert("Could not update library", isPresented: Binding(
            get: { libraryError != nil },
            set: { if !$0 { libraryError = nil } }
        )) {
            Button("OK", role: .cancel) { libraryError = nil }
        } message: {
            Text(libraryError ?? "")
        }
    }

    private var hasCurrentSource: Bool {
        loadedSourceRevision == model.sourceRevision(for: manga.sourceId)
            && model.source(id: manga.sourceId) != nil
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
        chapters = []
        defer { if generation == loadGeneration { loading = false } }
        guard let source = model.source(id: manga.sourceId) else {
            errorText = "Source not available for this manga."
            return
        }
        do {
            let execution = try model.sourceExecutionConfiguration(id: manga.sourceId, revision: revision)
            let existing = try await model.store.manga(sourceId: manga.sourceId, url: manga.url)
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
                expectedConfiguration: execution
            )
            guard canPublish(revision: revision, generation: generation) else { return }
            storedId = saved.manga.id
            inLibrary = saved.manga.inLibrary
            detail = compat
            chapters = saved.chapters
            loadedSourceRevision = revision
        } catch is CancellationError {
            return
        } catch {
            guard canPublish(revision: revision, generation: generation) else { return }
            errorText = "Could not load this manga: \(error.localizedDescription)"
        }
    }

    private func canPublish(revision: UInt64, generation: Int) -> Bool {
        !Task.isCancelled && generation == loadGeneration
            && model.isSourceCurrent(id: manga.sourceId, revision: revision)
    }

    private func toggleLibrary() {
        guard let id = storedId, !libraryBusy else { return }
        let adding = !inLibrary
        libraryBusy = true
        Task {
            defer { libraryBusy = false }
            do {
                try await model.setLibrary(adding, mangaId: id)
                inLibrary = adding
                if adding, !model.categories.isEmpty {
                    categoryAssignment = CategoryAssignmentRequest(mangaIDs: [id],
                                                                   title: detail?.title ?? manga.title)
                }
            } catch {
                libraryError = model.libraryErrorMessage(for: error)
            }
        }
    }

    private func categoryLabel(mangaId: Int64) -> String {
        let ids = model.librarySnapshot.categoryIDsByManga[mangaId] ?? []
        let names = model.categories.filter { $0.id.map(ids.contains) ?? false }.map(\.name)
        return names.isEmpty ? "Set categories" : names.joined(separator: ", ")
    }

    private func markRead(_ chapter: Chapter) {
        guard let id = chapter.id else { return }
        Task {
            try? await model.store.markRead(!chapter.read, chapterId: id)
            if let idx = chapters.firstIndex(where: { $0.id == id }) {
                chapters[idx].read.toggle()
            }
        }
    }
}
