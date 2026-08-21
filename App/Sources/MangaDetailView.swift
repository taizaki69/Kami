import SwiftUI
import MihonCompatKit
import KamiCore

struct MangaDetailView: View {
    @EnvironmentObject var model: AppModel

    let manga: Manga
    var prefetched: SMangaCompat?

    @State private var detail: SMangaCompat?
    @State private var chapters: [Chapter] = []
    @State private var inLibrary = false
    @State private var loading = true
    @State private var errorText: String?
    @State private var storedId: Int64?

    var body: some View {
        List {
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
            } else if let errorText {
                Section { Label(errorText, systemImage: "exclamationmark.triangle") }
            }

            Section("Chapters") {
                ForEach(chapters) { chapter in
                    NavigationLink {
                        ReaderView(mangaTitle: detail?.title ?? manga.title,
                                   chapter: chapter,
                                   source: model.source(id: manga.sourceId))
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
        .task { await load() }
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
        defer { loading = false }
        guard let source = model.source(id: manga.sourceId) else {
            errorText = "Source not available for this manga."
            return
        }
        do {
            try await model.store.upsert(manga, inLibrary: false)
            // INSERT OR IGNORE returns no rowid on conflict; resolve the real
            // stored id (and true library state) by identity.
            if let existing = try await model.store.manga(sourceId: manga.sourceId, url: manga.url) {
                storedId = existing.id
                inLibrary = existing.inLibrary
            }

            var compat = prefetched ?? SMangaCompat(url: manga.url, title: manga.title)
            if !compat.initialized {
                compat = try await source.getMangaDetails(manga: compat)
            }
            detail = compat

            let chapterList = try await source.getChapterList(manga: compat)
            let domain = chapterList.enumerated().map { order, c in
                Chapter(mangaId: mangaRowId, sourceOrder: order, from: c)
            }
            try await model.store.replaceChapters(mangaId: mangaRowId, with: domain)
            chapters = try await model.store.chapters(mangaId: mangaRowId)
        } catch {
            errorText = "Could not load this manga: \(error.localizedDescription)"
        }
    }

    private func toggleLibrary() {
        guard let id = storedId else { return }
        Task {
            try? await model.store.setLibrary(!inLibrary, mangaId: id)
            inLibrary.toggle()
            model.reloadLibrary()
        }
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
