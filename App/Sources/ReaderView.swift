import SwiftUI
import UIKit
import MihonCompatKit
import KamiCore

/// Native reader with persistent LTR, RTL, and continuous webtoon modes.
/// Page bytes flow through ReaderImagePipeline so source headers, redirect
/// policy, streamed limits, isolated cookies, cache bounds, and prefetching are
/// shared across every visible page in this chapter.
struct ReaderView: View {
    let mangaTitle: String
    let chapter: Chapter
    let source: (any KamiSource)?

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reader.mode") private var modeRaw = ReaderMode.leftToRight.rawValue
    @AppStorage("reader.background") private var backgroundRaw = ReaderBackground.black.rawValue
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("reader.prefetchPages") private var prefetchPages = 3
    @AppStorage("reader.webtoonGap") private var webtoonGap = 0.0

    @StateObject private var imageStore: ReaderImageStore
    @State private var pages: [PageCompat] = []
    @State private var currentIndex = 0
    @State private var errorText: String?
    @State private var loading = true
    @State private var showingSettings = false
    @State private var chromeVisible = true
    @State private var previousIdleTimerDisabled: Bool?
    @State private var loadGeneration = 0

    init(
        mangaTitle: String,
        chapter: Chapter,
        source: (any KamiSource)?
    ) {
        self.mangaTitle = mangaTitle
        self.chapter = chapter
        self.source = source
        _imageStore = StateObject(wrappedValue: ReaderImageStore(
            sourceID: String(source?.id ?? 0)
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundColor.ignoresSafeArea()

                if loading {
                    ProgressView("Loading chapter…")
                        .tint(foregroundColor)
                        .foregroundStyle(foregroundColor)
                } else if let errorText {
                    readerFailure(errorText)
                } else if pages.isEmpty {
                    readerFailure("This chapter has no pages.")
                } else {
                    readerContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(mangaTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(pageLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Reader settings")

                    Button("Done") { dismiss() }
                }
            }
            .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!chromeVisible)
        }
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingSettings) {
            ReaderSettingsSheet(
                modeRaw: $modeRaw,
                backgroundRaw: $backgroundRaw,
                keepScreenAwake: $keepScreenAwake,
                prefetchPages: $prefetchPages,
                webtoonGap: $webtoonGap
            )
        }
        .task { await load() }
        .onAppear {
            normalizeStoredSettings()
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            applyIdleTimerSetting()
        }
        .onDisappear {
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
            imageStore.stop()
        }
        .onChange(of: keepScreenAwake) { _, _ in
            applyIdleTimerSetting()
        }
        .onChange(of: prefetchPages) { _, _ in
            schedulePrefetch(around: currentIndex)
        }
        .onChange(of: currentIndex) { _, newIndex in
            guard pages.indices.contains(newIndex) else { return }
            schedulePrefetch(around: newIndex)
            persistProgress(newIndex)
        }
    }

    private var settings: ReaderSettings {
        ReaderSettings(
            mode: ReaderMode(rawValue: modeRaw) ?? .leftToRight,
            background: ReaderBackground(rawValue: backgroundRaw) ?? .black,
            keepScreenAwake: keepScreenAwake,
            prefetchPages: prefetchPages,
            webtoonGap: webtoonGap
        )
    }

    private var backgroundColor: Color {
        switch settings.background {
        case .black: return .black
        case .gray: return Color(white: 0.16)
        case .white: return .white
        }
    }

    private var foregroundColor: Color {
        settings.background == .white ? .black : .white
    }

    private var pageLabel: String {
        guard !pages.isEmpty else { return "" }
        return "\(currentIndex + 1) / \(pages.count)"
    }

    @ViewBuilder
    private var readerContent: some View {
        switch settings.mode {
        case .leftToRight, .rightToLeft:
            pagedReader
        case .webtoon:
            webtoonReader
        }
    }

    private var pagedReader: some View {
        TabView(selection: $currentIndex) {
            ForEach(pages.indices, id: \.self) { index in
                ReaderPageImage(
                    pageNumber: index + 1,
                    request: imageRequest(for: pages[index]),
                    store: imageStore,
                    layout: .paged,
                    isActive: abs(index - currentIndex) <= 1,
                    background: backgroundColor,
                    foreground: foregroundColor,
                    onSingleTap: handlePagedTap
                )
                .tag(index)
            }
        }
        .environment(
            \.layoutDirection,
            settings.mode == .rightToLeft ? .rightToLeft : .leftToRight
        )
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if !chromeVisible {
                Text(pageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(foregroundColor.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var webtoonReader: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: settings.webtoonGap) {
                        ForEach(pages.indices, id: \.self) { index in
                            ReaderPageImage(
                                pageNumber: index + 1,
                                request: imageRequest(for: pages[index]),
                                store: imageStore,
                                layout: .webtoon,
                                isActive: true,
                                background: backgroundColor,
                                foreground: foregroundColor,
                                onSingleTap: { _ in toggleChrome() }
                            )
                            .id(index)
                            .background {
                                GeometryReader { pageProxy in
                                    Color.clear.preference(
                                        key: ReaderPageFramePreferenceKey.self,
                                        value: [
                                            index: pageProxy.frame(
                                                in: .named("reader-webtoon")
                                            ),
                                        ]
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "reader-webtoon")
                .scrollIndicators(.hidden)
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(currentIndex, anchor: .top)
                    }
                }
                .onPreferenceChange(ReaderPageFramePreferenceKey.self) { frames in
                    updateWebtoonProgress(frames: frames, viewport: viewport.size)
                }
            }
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    private func readerFailure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func imageRequest(for page: PageCompat) -> ImageRequest? {
        source?.getImageRequest(page: page)
    }

    private func handlePagedTap(_ horizontalFraction: CGFloat) {
        if horizontalFraction < 0.25 {
            if settings.mode == .rightToLeft {
                advancePage()
            } else {
                retreatPage()
            }
        } else if horizontalFraction > 0.75 {
            if settings.mode == .rightToLeft {
                retreatPage()
            } else {
                advancePage()
            }
        } else {
            toggleChrome()
        }
    }

    private func advancePage() {
        guard currentIndex + 1 < pages.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1 }
    }

    private func retreatPage() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) { currentIndex -= 1 }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    private func updateWebtoonProgress(
        frames: [Int: CGRect],
        viewport: CGSize
    ) {
        let visibleBounds = CGRect(origin: .zero, size: viewport)
        let best = frames.compactMap { index, frame -> (Int, CGFloat)? in
            let intersection = frame.intersection(visibleBounds)
            guard !intersection.isNull, intersection.height > 0 else { return nil }
            return (index, intersection.height * max(intersection.width, 1))
        }.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0 > rhs.0
        }
        if let best, best.0 != currentIndex {
            currentIndex = best.0
        }
    }

    private func schedulePrefetch(around index: Int) {
        guard !pages.isEmpty else { return }
        let indexes = ReaderPrefetchPlan.indexes(
            pageCount: pages.count,
            currentIndex: index,
            ahead: settings.prefetchPages,
            behind: 1
        )
        imageStore.prefetch(indexes.compactMap { imageRequest(for: pages[$0]) })
    }

    private func persistProgress(_ page: Int) {
        guard let chapterID = chapter.id else { return }
        let reachedEnd = !pages.isEmpty && page == pages.count - 1
        Task {
            try? await model.store.updateProgress(chapterId: chapterID, page: page)
            try? await model.store.recordHistory(
                mangaId: chapter.mangaId,
                chapterId: chapterID
            )
            if reachedEnd {
                try? await model.store.markRead(true, chapterId: chapterID)
            }
        }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        errorText = nil
        await imageStore.reset()

        guard let source else {
            errorText = "Source not available."
            loading = false
            return
        }
        do {
            let compat = SChapterCompat(
                url: chapter.url,
                name: chapter.name,
                number: chapter.number == -1
                    ? nil
                    : String(format: "%g", chapter.number)
            )
            let loadedPages = try await source.getPageList(chapter: compat)
            guard generation == loadGeneration else { return }
            pages = loadedPages
            currentIndex = min(chapter.lastPageRead, max(loadedPages.count - 1, 0))
            loading = false
            if loadedPages.isEmpty {
                errorText = "This chapter has no pages."
            } else {
                schedulePrefetch(around: currentIndex)
                persistProgress(currentIndex)
            }
        } catch {
            guard generation == loadGeneration else { return }
            errorText = "Could not load pages: \(error.localizedDescription)"
            loading = false
        }
    }

    private func normalizeStoredSettings() {
        let normalized = settings
        modeRaw = normalized.mode.rawValue
        backgroundRaw = normalized.background.rawValue
        prefetchPages = normalized.prefetchPages
        webtoonGap = normalized.webtoonGap
    }

    private func applyIdleTimerSetting() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }
}

private struct ReaderPageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
