import SwiftUI
import KamiCore

struct UpdatesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No updates",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Library update scanning lands with the update service (see TODO.md).")
            )
            .navigationTitle("Updates")
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [(Manga, Chapter, Int64)] = []

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries, id: \.1.id) { manga, chapter, date in
                    HStack {
                        CoverImage(url: manga.thumbnailURL, cornerRadius: 4)
                            .frame(width: 36, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manga.title).lineLimit(1)
                            Text(chapter.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(date)), relativeTo: Date()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No history", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("History")
            .task {
                entries = (try? await model.store.history()) ?? []
            }
        }
    }
}
