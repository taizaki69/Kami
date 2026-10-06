import SwiftUI
import MihonCompatKit
import KamiCore

@MainActor
struct BrowseView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let presentation = model.libraryPresentation.generation
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        GlobalSearchView(presentation: presentation)
                    } label: {
                        Label("Search all sources", systemImage: "magnifyingglass")
                    }
                }
                Section("Sources") {
                    ForEach(model.sources, id: \.id) { source in
                        NavigationLink {
                            SourceBrowseView(source: source, presentation: presentation)
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

@MainActor
struct SourceBrowseView: View {
    @EnvironmentObject private var model: AppModel
    let sourceID: Int64
    let sourceName: String
    @State private var defaultFilters: [SourceFilter]
    @State private var presentation: LibraryPresentationGeneration

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
    @State private var filterRefreshCompleted = false
    @State private var filterRefreshInProgress = false
    @State private var filterSchemaReady = false
    @State private var sessionRevision: UInt64?
    @State private var requestTask: Task<Void, Never>?
    @State private var filterGeneration = 0

    init(source: any KamiSource, presentation: LibraryPresentationGeneration, initialQuery: String = "") {
        self.sourceID = source.id
        self.sourceName = source.name
        _presentation = State(initialValue: presentation)
        _query = State(initialValue: initialQuery)
        let filters = source.getFilterList()
        _defaultFilters = State(initialValue: filters)
        _appliedFilters = State(initialValue: filters)
        _filterSchemaReady = State(initialValue: !source.supportsFilterFetching)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case latest = "Latest"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if !hasCurrentSource {
                Section {
                    if model.source(id: sourceID) == nil {
                        Label("This source is disabled. Enable it in Extensions to browse again.",
                              systemImage: "pause.circle")
                            .font(.footnote)
                    } else {
                        ProgressView("Loading source…")
                    }
                }
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            Section {
                ForEach(hasCurrentSource ? items : [], id: \.url) { manga in
                    NavigationLink {
                        MangaDetailView(
                            manga: Manga(sourceId: sourceID, from: manga),
                            prefetched: manga,
                            prefetchedSourceRevision: sessionRevision, presentation: presentation
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
                if hasCurrentSource && hasNext {
                    Button {
                        startLoad(page: page + 1)
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
                if model.source(id: sourceID)?.supportsLatest == true {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .navigationTitle(sourceName)
        .searchable(text: $query, prompt: "Search \(sourceName)")
        .onSubmit(of: .search) {
            startLoad(page: 1, reset: true)
        }
        .onChange(of: query) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startLoad(page: 1, reset: true)
            }
        }
        .task(id: sourceRevision) {
            await model.runLibraryOperation(expected: presentation) {
                let revision = sourceRevision
                if sessionRevision != revision {
                    stopRequests()
                    items = []
                    hasNext = false
                    showingFilters = false
                    filterRefreshCompleted = false
                    guard let source = model.source(id: sourceID) else {
                        sessionRevision = nil
                        defaultFilters = []
                        appliedFilters = []
                        errorText = "Source not available. Enable it in Extensions to browse again."
                        return
                    }
                    sessionRevision = revision
                    defaultFilters = source.getFilterList()
                    appliedFilters = defaultFilters
                    filterSearchEnabled = false
                    filterSchemaReady = !source.supportsFilterFetching
                }
                if items.isEmpty { await load(page: 1, reset: true) }
                if model.source(id: sourceID)?.supportsFilterFetching == true {
                    await refreshFiltersIfNeeded()
                }
            }
        }
        .onDisappear { stopRequests() }
        .onChange(of: mode) { _, _ in
            filterSearchEnabled = false
            appliedFilters = defaultFilters
            startLoad(page: 1, reset: true)
        }
        .refreshable {
            await model.runLibraryOperation(expected: presentation) {
                requestTask?.cancel()
                if model.source(id: sourceID)?.supportsFilterFetching == true {
                    await refreshFiltersIfNeeded()
                }
                await load(page: 1, reset: true)
            }
        }
        .toolbar {
            if hasCurrentSource && !defaultFilters.isEmpty {
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
                    .disabled(!filterSchemaReady || filterRefreshInProgress)
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            SourceFilterSheet(
                sourceName: sourceName,
                filters: appliedFilters,
                defaults: defaultFilters,
                isFiltering: filterSearchEnabled,
                onApply: { filters in
                    appliedFilters = filters
                    filterSearchEnabled = true
                    startLoad(page: 1, reset: true)
                },
                onClear: {
                    appliedFilters = defaultFilters
                    filterSearchEnabled = false
                    startLoad(page: 1, reset: true)
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

    private var sourceRevision: UInt64 { model.sourceRevision(for: sourceID) }

    private var hasCurrentSource: Bool {
        sessionRevision == sourceRevision && model.source(id: sourceID) != nil
    }

    private func stopRequests() {
        requestTask?.cancel()
        requestTask = nil
        loadGeneration &+= 1
        filterGeneration &+= 1
        loading = false
        filterRefreshInProgress = false
    }

    private func startLoad(page: Int, reset: Bool = false) {
        guard hasCurrentSource else { return }
        requestTask?.cancel()
        requestTask = model.performLibraryOperation(expected: presentation) { await load(page: page, reset: reset) }
    }

    private func load(page requestedPage: Int, reset: Bool = false) async {
        guard !Task.isCancelled, hasCurrentSource,
              let source = model.source(id: sourceID),
              let revision = sessionRevision else { return }
        if !reset && loading { return }

        if reset {
            loadGeneration += 1
            items = []
            hasNext = false
        }
        let generation = loadGeneration
        let requestedMode = mode
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedFilterSearchEnabled = filterSearchEnabled
        let requestedFilters = requestedFilterSearchEnabled ? appliedFilters : []

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
                forceSearch: requestedFilterSearchEnabled
            )
            let result = try await request.execute(on: source)

            guard !Task.isCancelled, generation == loadGeneration,
                  model.isSourceCurrent(id: sourceID, revision: revision) else { return }
            if reset {
                items = result.mangas
            } else {
                items += result.mangas
            }
            page = requestedPage
            hasNext = result.hasNextPage
        } catch {
            guard generation == loadGeneration,
                  model.isSourceCurrent(id: sourceID, revision: revision) else { return }
            guard !Task.isCancelled else { return }
            errorText = "The source request failed: \(error.localizedDescription)"
        }
    }

    private func refreshFiltersIfNeeded() async {
        guard !Task.isCancelled,
              hasCurrentSource,
              let source = model.source(id: sourceID),
              let revision = sessionRevision,
              !filterRefreshCompleted,
              !filterRefreshInProgress else { return }
        let generation = filterGeneration
        filterRefreshInProgress = true
        defer {
            if generation == filterGeneration,
               model.isSourceCurrent(id: sourceID, revision: revision) {
                filterRefreshInProgress = false
                filterSchemaReady = true
            }
        }
        do {
            let refreshed = try await source.refreshFilterList()
            guard !Task.isCancelled, generation == filterGeneration,
                  model.isSourceCurrent(id: sourceID, revision: revision) else { return }
            // The source owns its retry ceiling. A nonthrowing placeholder is
            // therefore a completed refresh for this source instance.
            filterRefreshCompleted = true
            guard !refreshed.isEmpty else { return }
            defaultFilters = refreshed
            appliedFilters = refreshed
            filterSearchEnabled = false
        } catch {
            // Filter metadata is optional UI enrichment. Keep the source's
            // initial filters and do not replace a successful browse result
            // with a background refresh error.
        }
    }
}
