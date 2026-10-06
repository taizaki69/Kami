import SwiftUI
import KamiCore

@MainActor
final class GlobalSearchModel: ObservableObject {
    let session = GlobalSearchSession()
    @Published private(set) var state: GlobalSearchState

    init() {
        state = session.state
        session.onChange = { [weak self] in self?.state = $0 }
    }
}

@MainActor
struct GlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    let presentation: LibraryPresentationGeneration
    @StateObject private var search = GlobalSearchModel()
    @State private var query = ""
    @State private var requestTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var showingSelection = false

    var body: some View {
        List {
            Section {
                Text("Searches your selected, enabled sources using their default filters. Open a source for more results or to change filters.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showingSelection = true } label: {
                    Label("Sources and languages", systemImage: "line.3.horizontal.decrease.circle")
                }
                Text("\(model.discoverySources.count) of \(model.sources.count) enabled sources selected")
                    .font(.footnote).foregroundStyle(.secondary)
                if search.state.isSearching {
                    HStack {
                        ProgressView()
                        Text("\(search.state.completedSources) of \(search.state.groups.count) sources finished")
                            .font(.footnote)
                        Spacer()
                        Button("Cancel") { stop(clearResults: false) }
                    }
                }
                if let message = search.state.inputError?.errorDescription ?? notice {
                    Label(message, systemImage: "info.circle").font(.footnote)
                }
            }
            ForEach(search.state.groups) { group in
                if search.state.selectionID == model.sourceDiscovery.revision,
                   model.isSourceCurrent(id: group.sourceID, revision: group.revision) {
                    results(for: group)
                }
            }
            if search.state.groups.isEmpty && notice == nil && search.state.inputError == nil {
                ContentUnavailableView {
                    Label("Search sources", systemImage: "magnifyingglass")
                } description: {
                    Text("Enter a title and submit your search.")
                }
            }
        }
        .navigationTitle("Global search")
        .searchable(text: $query, prompt: "Search selected sources")
        .onSubmit(of: .search) { submit() }
        .onChange(of: query) { _, _ in
            stop(clearResults: true)
            notice = nil
        }
        .onChange(of: model.sourceGeneration) { _, _ in sourcesChanged() }
        .onChange(of: model.extensionBusyPackages) { _, _ in sourcesChanged() }
        .onChange(of: model.sourceDiscovery.revision) { _, _ in
            stop(clearResults: true)
            notice = "Source selection changed. Submit your search again."
        }
        .onDisappear { stop(clearResults: false) }
        .sheet(isPresented: $showingSelection) {
            SourceSelectionSheet(initial: model.sourceDiscovery)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { submit() } label: { Label("Search", systemImage: "magnifyingglass") }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func results(for group: GlobalSearchGroup) -> some View {
        Section {
            ForEach(group.matches) { match in
                NavigationLink {
                    currentDestination(group) {
                        MangaDetailView(manga: Manga(sourceId: group.sourceID, from: match.manga),
                            prefetched: match.manga, prefetchedSourceRevision: group.revision,
                            presentation: presentation)
                    }
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(url: match.thumbnailURL, cornerRadius: 4).frame(width: 44, height: 62)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title.isEmpty ? "Untitled manga" : match.title).lineLimit(2)
                            if let author = match.author {
                                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            switch group.phase {
            case .queued:
                Label("Waiting…", systemImage: "clock").foregroundStyle(.secondary)
            case .searching:
                ProgressView("Searching…")
            case .loaded:
                if group.matches.isEmpty { Text("No results").foregroundStyle(.secondary) }
            case .failed:
                Label("Search failed. Open this source to try again.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            case .unavailable:
                Text("This source changed. Submit a new search.").font(.footnote)
            case .cancelled:
                Text("Search cancelled").font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink {
                currentDestination(group) {
                    if let source = model.source(id: group.sourceID) {
                        SourceBrowseView(source: source, presentation: presentation, initialQuery: search.state.query)
                    }
                }
            } label: {
                Label(group.hasMore ? "More results in \(group.name)" : "Search in \(group.name)",
                      systemImage: "magnifyingglass")
            }
        } header: {
            Text("\(group.name) · \(group.language)")
        }
    }

    @ViewBuilder
    private func currentDestination<Content: View>(
        _ group: GlobalSearchGroup, @ViewBuilder content: () -> Content
    ) -> some View {
        // A result's path belongs to its original registration. It must not be
        // reinterpreted on a newly configured website after navigation.
        if search.state.selectionID == model.sourceDiscovery.revision,
           model.isSourceCurrent(id: group.sourceID, revision: group.revision),
           model.readySourceRegistrations().contains(where: { $0.registrationID == group.registrationID }) {
            content()
        } else {
            ContentUnavailableView("Source changed", systemImage: "arrow.clockwise",
                description: Text("Go back and submit a new search."))
        }
    }

    private func submit() {
        let text = query
        let registrations = model.readySourceRegistrations()
        let selection = model.sourceDiscoverySnapshot()
        let hasSelected = registrations.contains {
            selection.preferences.includes(sourceID: $0.sourceID, language: $0.source.language)
        }
        requestTask?.cancel()
        if model.sourceDiscovery.requiresRecovery {
            notice = "Review your saved source selection before searching."
        } else if registrations.isEmpty {
            notice = "No sources are ready. Enable a source in Extensions and try again."
        } else {
            notice = hasSelected ? nil : "No ready sources match your selection. Choose sources or languages and try again."
        }
        requestTask = model.performLibraryOperation(expected: presentation) {
            await search.session.search(query: text, registrations: registrations, selection: selection)
        }
    }

    private func stop(clearResults: Bool) {
        requestTask?.cancel()
        requestTask = nil
        search.session.cancel(clearResults: clearResults)
    }

    private func sourcesChanged() {
        stop(clearResults: true)
        if !query.isEmpty { notice = "Sources changed. Submit your search again." }
    }
}
