import SwiftUI
import MihonCompatKit
import KamiCore

@MainActor
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var category: LibraryCategoryFilter = .all
    @State private var showCategories = false
    @State private var selecting = false
    @State private var selectedIDs = Set<Int64>()
    @State private var selectionContext: LibraryMutationContext?
    @State private var assignment: CategoryAssignmentRequest?
    @State private var showDownloads = false
    @State private var showBackups = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        let snapshot = model.librarySnapshot
        let filtered = snapshot.filteredManga(category: category, search: search)
        NavigationStack {
            VStack(spacing: 0) {
                categoryPicker
                if let message = model.libraryError {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Retry") { Task { await model.refreshLibrary() } }
                    }
                    .font(.footnote)
                    .padding()
                }
                ScrollView {
                    if model.loading && model.library.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if filtered.isEmpty {
                        emptyState.padding(.top, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filtered) { manga in
                                mangaCell(manga, context: snapshot.mutationContext)
                            }
                        }
                        .padding()
                    }
                }
                .refreshable { await model.refreshLibrary() }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showDownloads = true
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    Menu {
                        Button {
                            showCategories = true
                        } label: {
                            Label("Manage categories", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            showBackups = true
                        } label: {
                            Label("Library backups", systemImage: "externaldrive")
                        }
                    } label: {
                        Label("Library options", systemImage: "ellipsis.circle")
                    }
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selectedIDs.removeAll()
                        selectionContext = selecting ? snapshot.mutationContext : nil
                    }
                    .disabled(model.library.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar(filtered: filtered, context: snapshot.mutationContext) }
            }
            .navigationDestination(for: Manga.self) { manga in
                MangaDetailView(manga: manga)
            }
            .task {
                await model.refreshLibrary()
                await model.refreshDownloadCounts()
            }
            .sheet(isPresented: $showDownloads) { DownloadsView() }
            .sheet(isPresented: $showCategories) { CategoriesView() }
            .sheet(isPresented: $showBackups) { LibraryBackupsView() }
            .sheet(item: $assignment) { request in
                CategoryAssignmentSheet(mangaIDs: request.mangaIDs, title: request.title, context: request.context)
            }
            .onChange(of: model.categories) { _, _ in
                category = model.librarySnapshot.availableFilter(category)
            }
            .onChange(of: filtered.compactMap(\.id)) { _, ids in
                selectedIDs.formIntersection(Set(ids))
            }
            .onChange(of: model.librarySnapshot.mutationContext) { _, _ in
                selectedIDs.removeAll()
                selectionContext = nil
                selecting = false
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryButton("All", filter: .all)
                categoryButton("Uncategorized", filter: .uncategorized)
                ForEach(model.categories) { category in
                    if let id = category.id {
                        categoryButton(category.name, filter: .category(id))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func categoryButton(_ name: String, filter: LibraryCategoryFilter) -> some View {
        Button {
            category = filter
        } label: {
            HStack(spacing: 4) {
                Text(name)
                Text("\(model.librarySnapshot.mangaCount(in: filter))")
                    .font(.caption.monospacedDigit())
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(category == filter ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(category == filter ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(category == filter ? .isSelected : [])
    }

    @ViewBuilder
    private func mangaCell(_ manga: Manga, context: LibraryMutationContext?) -> some View {
        if selecting, let id = manga.id {
            Button {
                guard context == selectionContext else { return }
                if selectedIDs.contains(id) { selectedIDs.remove(id) }
                else { selectedIDs.insert(id) }
            } label: {
                MangaCoverCell(manga: manga)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.accentColor, Color.white)
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(manga.title)
            .accessibilityValue(selectedIDs.contains(id) ? "Selected" : "Not selected")
        } else {
            NavigationLink(value: manga) { MangaCoverCell(manga: manga) }
                .buttonStyle(.plain)
                .contextMenu {
                    if let id = manga.id {
                        Button {
                            assignment = CategoryAssignmentRequest(mangaIDs: [id], title: manga.title, context: context)
                        } label: {
                            Label("Set categories", systemImage: "folder")
                        }
                    }
                }
        }
    }

    private func selectionBar(filtered: [Manga], context: LibraryMutationContext?) -> some View {
        HStack {
            Text("\(selectedIDs.count) selected").font(.subheadline)
            Spacer()
            Button("Select shown") {
                selectedIDs = Set(filtered.compactMap(\.id))
                selectionContext = context
            }
                .disabled(filtered.isEmpty)
            Button("Categories") {
                assignment = CategoryAssignmentRequest(mangaIDs: selectedIDs,
                    title: "\(selectedIDs.count) manga", context: selectionContext)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
        }
        .padding()
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        let hasSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title: String
        let description: String
        if model.library.isEmpty {
            title = "Library is empty"
            description = "Browse a source and add manga to your library."
        } else if hasSearch {
            title = "No matches"
            description = "Try another search or category."
        } else {
            title = category == .uncategorized ? "No uncategorized manga" : "Category is empty"
            description = "Use Select or a manga's Set categories action to organize your library."
        }
        return ContentUnavailableView(title, systemImage: hasSearch ? "magnifyingglass" : "books.vertical",
                                      description: Text(description))
    }
}

struct MangaCoverCell: View {
    let manga: Manga
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                CoverImage(url: manga.thumbnailURL, cornerRadius: 8)
                    .aspectRatio(2 / 3, contentMode: .fit)
                if let source = model.source(id: manga.sourceId) {
                    Text(source.name)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let id = manga.id, let count = model.downloadedChapterCounts[id], count > 0 {
                    Label("\(count)", systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                        .accessibilityLabel("\(count) downloaded chapters")
                }
            }
            Text(manga.title)
                .font(.footnote)
                .lineLimit(2)
        }
    }
}

/// Cover loading with per-source headers (Referer etc.) where required.
struct CoverImage: View {
    let url: String?
    var cornerRadius: CGFloat = 0

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
