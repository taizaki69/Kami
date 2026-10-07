import SwiftUI
import KamiCore

@MainActor
struct SourceMigrationView: View {
    @EnvironmentObject private var model: AppModel
    let origin: MangaReadingSnapshot
    let title: String
    let presentation: LibraryPresentationGeneration
    @StateObject private var search = GlobalSearchModel()
    @State private var query: String
    @State private var searchTask: Task<Void, Never>?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparing = false
    @State private var preview: SourceMigrationPreview?
    @State private var notice: String?
    @State private var showingSelection = false

    init(origin: MangaReadingSnapshot, title: String, presentation: LibraryPresentationGeneration) {
        self.origin = origin; self.title = title; self.presentation = presentation
        _query = State(initialValue: title)
    }

    var body: some View {
        List {
            Section("Choose a destination for \(title)") {
                Text("Search your selected sources, then review chapter matches. The original manga and its downloads stay in your library.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showingSelection = true } label: {
                    Label("Sources and languages", systemImage: "line.3.horizontal.decrease.circle")
                }
                if preparing { ProgressView("Preparing migration preview…") }
                if search.state.isSearching {
                    ProgressView("\(search.state.completedSources) of \(search.state.groups.count) sources finished")
                }
                if preparing || search.state.isSearching {
                    Button("Cancel requests") { stop() }
                }
                if let message = search.state.inputError?.errorDescription ?? notice {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(search.state.groups) { group in
                if search.state.selectionID == model.sourceDiscovery.revision,
                   model.isSourceCurrent(id: group.sourceID, revision: group.revision) {
                    Section("\(group.name) · \(group.language)") {
                        ForEach(group.matches) { match in
                            Button { prepare(match, group: group) } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: match.thumbnailURL, cornerRadius: 4).frame(width: 44, height: 62)
                                    VStack(alignment: .leading) {
                                        Text(match.title.isEmpty ? "Untitled manga" : match.title).lineLimit(2)
                                        if let author = match.author {
                                            Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }.disabled(preparing)
                        }
                        if group.phase == .loaded && group.matches.isEmpty { Text("No results").foregroundStyle(.secondary) }
                        if group.phase == .failed { Text("Search failed. Submit again to retry.").font(.footnote) }
                        if group.phase == .queued || group.phase == .searching { ProgressView() }
                        if group.phase == .cancelled || group.phase == .unavailable { Text("Submit again to refresh results.").font(.footnote) }
                        if group.hasMore { Text("Showing the first results. Refine your search to find another destination.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Migrate manga")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find the destination manga")
        .onSubmit(of: .search) { submit() }
        .onChange(of: query) { _, _ in stop(clearResults: true); notice = nil }
        .onChange(of: model.sourceGeneration) { _, _ in sourcesChanged() }
        .onChange(of: model.extensionBusyPackages) { _, _ in sourcesChanged() }
        .onChange(of: model.sourceDiscovery.revision) { _, _ in sourcesChanged() }
        .onDisappear { stop() }
        .sheet(isPresented: $showingSelection) { SourceSelectionSheet(initial: model.sourceDiscovery) }
        .sheet(item: $preview) { item in SourceMigrationReview(preview: item, presentation: presentation).id(item.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { submit() } label: { Label("Search", systemImage: "magnifyingglass") }
                    .disabled(preparing || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submit() {
        guard !preparing else { return }
        let text = query, registrations = model.readySourceRegistrations()
        let selection = model.sourceDiscoverySnapshot()
        searchTask?.cancel()
        notice = registrations.contains {
            selection.preferences.includes(sourceID: $0.sourceID, language: $0.source.language)
        } ? nil : "No ready sources match your selection. Choose sources and languages before searching."
        searchTask = model.performLibraryOperation(expected: presentation) {
            await search.session.search(query: text, registrations: registrations, selection: selection)
        }
    }

    private func prepare(_ match: GlobalSearchMatch, group: GlobalSearchGroup) {
        guard !preparing, search.state.selectionID == model.sourceDiscovery.revision,
              let registration = model.readySourceRegistrations().first(where: { $0.registrationID == group.registrationID })
        else { notice = "The source changed. Submit a new search."; return }
        searchTask?.cancel()
        search.session.cancel()
        let selection = model.sourceDiscoverySnapshot()
        preparing = true
        notice = nil
        let worker = model.performLibraryOperation(expected: presentation) {
            do {
                let value = try await model.prepareSourceMigration(origin: origin, match: match,
                    registration: registration, selection: selection)
                try Task.checkCancellation()
                preview = value
            } catch is CancellationError {
                notice = "Preview cancelled. No manga data was changed."
            } catch {
                notice = (error as? SourceMigrationError)?.errorDescription
                    ?? "The destination could not be prepared. No manga data was changed. Search again or choose another result."
            }
        }
        guard let worker else { preparing = false; return }
        // Cleanup belongs to the observer too: the lease can be cancelled
        // before its closure starts. Do not leave the screen permanently busy.
        preparationTask = Task { @MainActor in
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            preparing = false
            preparationTask = nil
        }
    }

    private func stop(clearResults: Bool = false) {
        searchTask?.cancel()
        preparationTask?.cancel()
        search.session.cancel(clearResults: clearResults)
    }

    private func sourcesChanged() {
        stop(clearResults: true)
        preview = nil
        notice = "Sources or languages changed. Search again before migrating."
    }
}

@MainActor
private struct SourceMigrationReview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let preview: SourceMigrationPreview
    let presentation: LibraryPresentationGeneration
    @State private var draft: SourceMigrationDraft
    @State private var copyCategories = true
    @State private var reviewedRevision: UUID?
    @State private var reviewedCategories: Bool?
    @State private var showingReset = false
    @State private var errorText: String?
    @State private var expired = false

    init(preview: SourceMigrationPreview, presentation: LibraryPresentationGeneration) {
        self.preview = preview; self.presentation = presentation
        _draft = State(initialValue: preview.makeDraft())
    }

    private var reviewed: Bool { reviewedRevision == draft.revision && reviewedCategories == copyCategories }

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    Text(preview.destination.manga.title).font(.headline)
                    Text("\(preview.destination.sourceName) · \(preview.destination.language)")
                    Text(preview.destination.manga.url).font(.caption).textSelection(.enabled)
                    Text(preview.destinationExists ? "Already saved: existing metadata and reading progress will be kept." : "This manga will be added to your library.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("What will be copied") {
                    Text("Read status and bookmarks from \(draft.matchedCount) selected chapter matches. Existing destination flags stay set.")
                    if !preview.categoryNames.isEmpty {
                        Toggle("Copy categories", isOn: $copyCategories)
                        Text(preview.categoryNames.joined(separator: ", ")).font(.footnote)
                    }
                    Text("The original stays in your library. History, downloads and page positions stay with their original chapters. New destination chapters start at page 1.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Chapter coverage") {
                    Text("\(draft.matchedCount) selected pairs: \(draft.manualCount) manual, \(draft.matchedCount - draft.manualCount) suggested by number")
                    Text("\(draft.unmatchedOriginalCount) original and \(draft.unmatchedDestinationCount) destination chapters remain unmatched.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Match chapters manually") {
                        SourceMigrationChapterEditor(preview: preview, draft: $draft)
                    }
                    Button("Reset to number suggestions") { showingReset = true }
                }
                Section {
                    ForEach(draft.pairs) { pair in
                        HStack {
                            NavigationLink {
                                SourceMigrationDestinationPicker(preview: preview, originalIndex: pair.originalIndex, draft: $draft)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preview.original.chapters[pair.originalIndex].name)
                                    Text("→ \(preview.destination.manga.chapters[pair.destinationIndex].name)").font(.subheadline)
                                    Text(draft.isNumberSuggestion(pair) ? "Suggested by number" : "Manual match")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                do { try draft.assign(destination: nil, to: pair.originalIndex) }
                                catch { errorText = error.localizedDescription }
                            } label: { Label("Remove match", systemImage: "minus.circle") }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                } header: { Text("Review selected pairs") } footer: {
                    Text("Check chapter titles, editions and scanlators before copying. Open a pair to review its details or choose a different destination. Each destination can be paired once; chapter numbers do not prove identical content.")
                }
                Section {
                    Toggle("I checked the destination and selected matches", isOn: Binding(
                        get: { reviewed }, set: {
                            reviewedRevision = $0 ? draft.revision : nil
                            reviewedCategories = $0 ? copyCategories : nil
                        }))
                    Button("Add destination and copy selected state") { commit() }
                        .disabled(!reviewed || expired || model.libraryPresentation.isExclusive)
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
            .disabled(model.libraryPresentation.isExclusive)
            .safeAreaInset(edge: .bottom) {
                if model.libraryPresentation.isExclusive {
                    HStack {
                        ProgressView("Saving migration…")
                        Spacer()
                        Button("Cancel") { model.cancelExclusiveLibraryChange() }
                    }.padding().background(.regularMaterial)
                }
            }
            .interactiveDismissDisabled(model.libraryPresentation.isExclusive)
            .navigationTitle("Review migration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(model.libraryPresentation.isExclusive)
                }
            }
            .confirmationDialog("Replace your chapter choices with number suggestions?", isPresented: $showingReset) {
                Button("Reset suggested pairs", role: .destructive) { draft.resetToSuggestions() }
            }
            .onChange(of: draft.revision) { _, _ in reviewedRevision = nil }
            .onChange(of: copyCategories) { _, _ in reviewedCategories = nil }
            .onChange(of: model.sourceMigrationFailure?.id) { _, _ in
                if let failure = model.sourceMigrationFailure, failure.previewID == preview.id {
                    errorText = failure.message; expired = true
                }
            }
        }
    }

    private func commit() {
        do {
            try model.beginSourceMigration(preview, selection: draft.selection,
                copyCategories: copyCategories, expected: presentation)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Migration is unavailable. Prepare a new preview."
        }
    }

}
