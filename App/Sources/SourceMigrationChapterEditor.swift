import SwiftUI
import KamiCore

@MainActor
private final class MigrationChapterSearchModel: ObservableObject {
    @Published private(set) var result: SourceMigrationChapterSearch?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var worker: Task<SourceMigrationChapterSearch, Error>?

    func search(chapters: [LibraryBackupDocument.Chapter], query: String, excluding: Set<Int>, page: Int) async {
        let previous = worker
        previous?.cancel()
        let token = UUID()
        generation = token
        result = nil; error = nil; loading = true
        let task = Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            try Task.checkCancellation()
            return try SourceMigrationChapterSearch.search(chapters: chapters, query: query, excluding: excluding, page: page)
        }
        worker = task
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            if generation == token { result = value }
        } catch is CancellationError {
            // The parent lifecycle still awaits the owned worker's drainage.
        } catch {
            if generation == token { self.error = (error as? SourceMigrationChapterSearchError)?.errorDescription ?? "Chapter search is unavailable." }
        }
        if generation == token { worker = nil; loading = false }
    }
}

private struct MigrationChapterSearchKey: Equatable {
    let previewID: UUID
    let originalIndex: Int?
    let query: String
    let page: Int
    let filtered: Bool
    let revision: UUID
}

@MainActor
struct SourceMigrationChapterEditor: View {
    let preview: SourceMigrationPreview
    @Binding var draft: SourceMigrationDraft
    @StateObject private var search = MigrationChapterSearchModel()
    @State private var query = ""
    @State private var unmatchedOnly = true
    @State private var page = 0

    var body: some View {
        List {
            Section {
                Toggle("Only unmatched originals", isOn: $unmatchedOnly)
                Text("Choose an original chapter, then select its destination. \(draft.unmatchedOriginalCount) originals remain unmatched.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if search.loading { ProgressView("Searching chapters…") }
            if let error = search.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let result = search.result {
                Section("Original chapters") {
                    ForEach(result.indices, id: \.self) { index in
                        NavigationLink {
                            SourceMigrationDestinationPicker(preview: preview, originalIndex: index, draft: $draft)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MigrationChapterLabel(chapter: preview.original.chapters[index])
                                if let destination = draft.destination(for: index) {
                                    Text("→ \(preview.destination.manga.chapters[destination].name)").font(.caption)
                                } else {
                                    Text(unmatchedReason(index)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if result.indices.isEmpty { Text("No matching chapters").foregroundStyle(.secondary) }
                }
                MigrationChapterPagination(result: result, page: $page)
            }
        }
        .navigationTitle("Match chapters")
        .searchable(text: $query, prompt: "Title, number or scanlator")
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: unmatchedOnly) { _, _ in page = 0 }
        .onChange(of: draft.revision) { _, _ in page = 0 }
        .task(id: MigrationChapterSearchKey(previewID: preview.id, originalIndex: nil,
                                          query: query, page: page, filtered: unmatchedOnly, revision: draft.revision)) {
            await search.search(chapters: preview.original.chapters, query: query,
                excluding: unmatchedOnly ? draft.matchedOriginalIndices : [], page: page)
        }
    }

    private func unmatchedReason(_ index: Int) -> String {
        switch preview.matching.unmatched.first(where: { $0.id == index })?.reason {
        case .unknownNumber: "No known chapter number; choose a destination manually"
        case .ambiguousNumber: "Duplicate chapter number; choose a destination manually"
        case .noDestination: "No number suggestion; choose a destination manually"
        case nil: "No selected destination"
        }
    }
}

@MainActor
struct SourceMigrationDestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    let preview: SourceMigrationPreview
    let originalIndex: Int
    @Binding var draft: SourceMigrationDraft
    @StateObject private var search = MigrationChapterSearchModel()
    @State private var query = ""
    @State private var availableOnly = true
    @State private var page = 0
    @State private var error: String?

    private var excluded: Set<Int> {
        guard availableOnly else { return [] }
        var indices = draft.matchedDestinationIndices
        if let current = draft.destination(for: originalIndex) { indices.remove(current) }
        return indices
    }

    var body: some View {
        List {
            Section("Original chapter") {
                MigrationChapterLabel(chapter: preview.original.chapters[originalIndex])
                if draft.destination(for: originalIndex) != nil {
                    Button("Remove this match", role: .destructive) { assign(nil) }
                }
                Toggle("Only available destinations", isOn: $availableOnly)
                Text("Compare titles, editions and scanlators. A destination already paired with another original must be freed there first.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if search.loading { ProgressView("Searching chapters…") }
            if let error = search.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let result = search.result {
                Section("Destination chapters") {
                    ForEach(result.indices, id: \.self) { index in
                        let owner = draft.original(for: index)
                        Button { assign(index) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MigrationChapterLabel(chapter: preview.destination.manga.chapters[index])
                                if let owner {
                                    if owner == originalIndex { Label("Selected destination", systemImage: "checkmark.circle.fill").font(.caption) }
                                    else { Text("Paired with: \(preview.original.chapters[owner].name)").font(.caption) }
                                }
                            }
                        }.disabled(owner != nil && owner != originalIndex)
                    }
                    if result.indices.isEmpty { Text("No matching destinations").foregroundStyle(.secondary) }
                }
                MigrationChapterPagination(result: result, page: $page)
            }
        }
        .navigationTitle("Choose destination")
        .searchable(text: $query, prompt: "Title, number or scanlator")
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: availableOnly) { _, _ in page = 0 }
        .onChange(of: draft.revision) { _, _ in page = 0 }
        .task(id: MigrationChapterSearchKey(previewID: preview.id, originalIndex: originalIndex,
                                          query: query, page: page, filtered: availableOnly, revision: draft.revision)) {
            await search.search(chapters: preview.destination.manga.chapters, query: query, excluding: excluded, page: page)
        }
    }

    private func assign(_ destination: Int?) {
        do { try draft.assign(destination: destination, to: originalIndex); dismiss() }
        catch { self.error = (error as? SourceMigrationError)?.errorDescription ?? "The match could not be changed." }
    }
}

private struct MigrationChapterLabel: View {
    let chapter: LibraryBackupDocument.Chapter
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chapter.name.isEmpty ? "Untitled chapter" : chapter.name).lineLimit(2)
            Text(chapter.number >= 0 ? "Number \(String(chapter.number))" : "Unknown number")
                .font(.caption).foregroundStyle(.secondary)
            if let scanlator = chapter.scanlator { Text(scanlator).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text(chapter.url).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            HStack {
                if chapter.read { Label("Read", systemImage: "checkmark").font(.caption) }
                if chapter.bookmark { Label("Bookmarked", systemImage: "bookmark.fill").font(.caption) }
            }
        }
    }
}

private struct MigrationChapterPagination: View {
    let result: SourceMigrationChapterSearch
    @Binding var page: Int
    var body: some View {
        Section {
            Text("\(result.totalMatches) matching chapters · Page \(result.page + 1)")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Previous") { page = result.page - 1 }.disabled(result.page == 0)
                Spacer()
                Button("Next") { page = result.page + 1 }.disabled(!result.hasNextPage)
            }.buttonStyle(.borderless)
        }
    }
}
