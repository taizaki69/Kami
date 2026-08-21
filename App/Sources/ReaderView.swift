import SwiftUI
import MihonCompatKit
import KamiCore

/// Paged reader (LTR/RTL/vertical paging via TabView; continuous webtoon mode
/// is a tracked next step — see docs/READER.md). Pages are fetched through
/// the source so per-source headers (Referer, User-Agent) are honored.
struct ReaderView: View {
    let mangaTitle: String
    let chapter: Chapter
    let source: (any KamiSource)?

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pages: [PageCompat] = []
    @State private var currentIndex = 0
    @State private var errorText: String?
    @State private var loading = true
    @State private var zoomed = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading chapter…")
                } else if let errorText {
                    VStack(spacing: 12) {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Retry") { Task { await load() } }
                    }
                    .padding()
                } else {
                    readerPager
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(mangaTitle).font(.subheadline).lineLimit(1)
                        Text(pageLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var pageLabel: String {
        guard !pages.isEmpty else { return "" }
        return "\(currentIndex + 1) / \(pages.count)"
    }

    private var readerPager: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                ReaderPageView(page: page, source: source)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
        .gesture(
            TapGesture(count: 2).onEnded { zoomed.toggle() }
        )
        .onChange(of: currentIndex) { newIndex in
            Task {
                if let chapterId = chapter.id {
                    try? await model.store.updateProgress(chapterId: chapterId, page: newIndex)
                    try? await model.store.recordHistory(mangaId: chapter.mangaId, chapterId: chapterId)
                }
            }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let source else {
            errorText = "Source not available."
            return
        }
        do {
            let compat = SChapterCompat(
                url: chapter.url,
                name: chapter.name,
                number: chapter.number == -1 ? nil : String(format: "%g", chapter.number)
            )
            pages = try await source.getPageList(chapter: compat)
            if pages.isEmpty {
                errorText = "This chapter has no pages."
            }
            currentIndex = min(chapter.lastPageRead, max(pages.count - 1, 0))
        } catch {
            errorText = "Could not load pages: \(error.localizedDescription)"
        }
    }
}

/// A single reader page: AsyncImage + retry, honoring source image headers.
struct ReaderPageView: View {
    let page: PageCompat
    let source: (any KamiSource)?

    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let request = source?.getImageRequest(page: page),
               let url = URL(string: request.url) {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .transition(.opacity)
                    case .empty:
                        ProgressView().tint(.white)
                    case .failure:
                        failureView
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                failureView
            }
        }
    }

    private var failureView: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text("Failed to load page \(page.index + 1)")
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
