import SwiftUI
import MihonCompatKit
import KamiCore

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    private var filtered: [Manga] {
        search.isEmpty ? model.library : model.library.filter {
            $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Library is empty",
                        systemImage: "books.vertical",
                        description: Text("Browse a source and add manga to your library.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filtered) { manga in
                                NavigationLink(value: manga) {
                                    MangaCoverCell(manga: manga)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search library")
            .navigationDestination(for: Manga.self) { manga in
                MangaDetailView(manga: manga)
            }
        }
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
        AsyncImage(url: url.map(URL.init(string:))) { phase in
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
