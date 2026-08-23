import SwiftUI
import MihonCompatKit
import KamiCore

struct BrowseView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Sources") {
                    ForEach(model.sources, id: \.id) { source in
                        NavigationLink {
                            SourceBrowseView(source: source)
                        } label: {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text("\(source.language) · \(originLabel(source.id))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("""
                    Authenticated, enabled extensions with a measured runtime \
                    profile appear beside native sources. Unsupported APKs stay \
                    installed but disabled until their compatibility profile is \
                    implemented.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Browse")
        }
    }

    private func originLabel(_ sourceID: Int64) -> String {
        switch model.sourceOrigin(id: sourceID) {
        case .native: return "native"
        case .pinnedCompatibilityProfile: return "built-in extension profile"
        case .downloadedExtension: return "installed extension"
        case nil: return "source"
        }
    }
}

struct SourceBrowseView: View {
    let source: any KamiSource

    @EnvironmentObject var model: AppModel
    @State private var mode: Mode = .popular
    @State private var query = ""
    @State private var page = 1
    @State private var items: [SMangaCompat] = []
    @State private var hasNext = false
    @State private var loading = false
    @State private var errorText: String?

    enum Mode: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case latest = "Latest"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            Section {
                ForEach(items, id: \.url) { manga in
                    NavigationLink {
                        MangaDetailView(
                            manga: Manga(sourceId: source.id, from: manga),
                            prefetched: manga
                        )
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(url: manga.thumbnailURL, cornerRadius: 4)
                                .frame(width: 44, height: 62)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manga.title).lineLimit(2)
                                if let author = manga.author {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if hasNext {
                    Button {
                        page += 1
                        Task { await load() }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView().padding(.trailing, 8) }
                            Text("Load more")
                            Spacer()
                        }
                    }
                }
            } header: {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(source.name)
        .searchable(text: $query, prompt: "Search \(source.name)")
        .onSubmit(of: .search) {
            page = 1
            Task { await load(reset: true) }
        }
        .onChange(of: query) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page = 1
                Task { await load(reset: true) }
            }
        }
        .task {
            if items.isEmpty { await load(reset: true) }
        }
        .onChange(of: mode) { _ in
            page = 1
            Task { await load(reset: true) }
        }
    }

    private func load(reset: Bool = false) async {
        if reset { items = [] }
        loading = true
        errorText = nil
        do {
            let result: MangasPageCompat
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                result = try await source.getSearchManga(
                    page: page,
                    query: trimmedQuery,
                    filters: []
                )
            } else {
                switch mode {
                case .popular: result = try await source.getPopularManga(page: page)
                case .latest: result = try await source.getLatestUpdates(page: page)
                }
            }
            items += result.mangas
            hasNext = result.hasNextPage
        } catch {
            errorText = "The source request failed: \(error.localizedDescription)"
        }
        loading = false
    }
}
