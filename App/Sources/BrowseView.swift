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
    private let defaultFilters: [SourceFilter]

    @State private var mode: Mode = .popular
    @State private var query = ""
    @State private var page = 1
    @State private var appliedFilters: [SourceFilter]
    @State private var filterSearchEnabled = false
    @State private var showingFilters = false
    @State private var items: [SMangaCompat] = []
    @State private var hasNext = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var loadGeneration = 0

    init(source: any KamiSource) {
        self.source = source
        let filters = source.getFilterList()
        defaultFilters = filters
        _appliedFilters = State(initialValue: filters)
    }

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
                        Task { await load(page: page + 1) }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView().padding(.trailing, 8) }
                            Text("Load more")
                            Spacer()
                        }
                    }
                    .disabled(loading)
                }
            } header: {
                if source.supportsLatest {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .navigationTitle(source.name)
        .searchable(text: $query, prompt: "Search \(source.name)")
        .onSubmit(of: .search) {
            Task { await load(page: 1, reset: true) }
        }
        .onChange(of: query) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await load(page: 1, reset: true) }
            }
        }
        .task {
            if items.isEmpty { await load(page: 1, reset: true) }
        }
        .onChange(of: mode) { _ in
            filterSearchEnabled = false
            appliedFilters = defaultFilters
            Task { await load(page: 1, reset: true) }
        }
        .refreshable {
            await load(page: 1, reset: true)
        }
        .toolbar {
            if !defaultFilters.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: filterSearchEnabled
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(filterSearchEnabled
                                        ? "Edit active filters"
                                        : "Filters")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            SourceFilterSheet(
                sourceName: source.name,
                filters: appliedFilters,
                defaults: defaultFilters,
                isFiltering: filterSearchEnabled,
                onApply: { filters in
                    appliedFilters = filters
                    filterSearchEnabled = true
                    Task { await load(page: 1, reset: true) }
                },
                onClear: {
                    appliedFilters = defaultFilters
                    filterSearchEnabled = false
                    Task { await load(page: 1, reset: true) }
                }
            )
        }
        .overlay {
            if loading && items.isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private func load(page requestedPage: Int, reset: Bool = false) async {
        if !reset && loading { return }

        if reset {
            loadGeneration += 1
            items = []
            hasNext = false
        }
        let generation = loadGeneration
        let requestedMode = mode
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedFilters = appliedFilters

        loading = true
        errorText = nil
        defer {
            if generation == loadGeneration {
                loading = false
            }
        }

        do {
            let request = SourceBrowseRequest(
                page: requestedPage,
                feed: requestedMode == .popular ? .popular : .latest,
                query: requestedQuery,
                filters: requestedFilters,
                forceSearch: filterSearchEnabled
            )
            let result = try await request.execute(on: source)

            guard generation == loadGeneration else { return }
            if reset {
                items = result.mangas
            } else {
                items += result.mangas
            }
            page = requestedPage
            hasNext = result.hasNextPage
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "The source request failed: \(error.localizedDescription)"
        }
    }
}
