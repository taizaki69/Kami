import SwiftUI
import UIKit
import MihonCompatKit
import KamiCore

enum ReaderOpeningPolicy: Equatable {
    case automatic, offlineOnly, onlineOnly
}

struct OfflineReaderChapter {
    let manga: Manga
    let chapter: Chapter
    let neighbours: [Chapter]
    let lease: OfflineChapterLease
}

/// Native reader with persistent LTR, RTL, and continuous webtoon modes.
/// Page bytes flow through ReaderImagePipeline so source headers, redirect
/// policy, streamed limits, isolated cookies, cache bounds, and prefetching are
/// shared across every visible page in this chapter.
@MainActor
struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    let mangaTitle: String
    let chapters: [Chapter]
    let sourceID: Int64
    let openingPolicy: ReaderOpeningPolicy
    @State private var chapter: Chapter
    @State private var readerChapters: [Chapter]
    @State private var offlineLease: OfflineChapterLease?
    @State private var loadingProvider = true
    @State private var providerError: String?
    @State private var requireOffline = false
    @State private var requestedOnline = false
    @State private var retryID = 0
    @State private var providerGeneration: UInt64 = 0

    init(mangaTitle: String, chapter: Chapter, chapters: [Chapter] = [], sourceID: Int64,
         openingPolicy: ReaderOpeningPolicy = .automatic) {
        self.mangaTitle = mangaTitle
        self.chapters = chapters
        self.sourceID = sourceID
        self.openingPolicy = openingPolicy
        _chapter = State(initialValue: chapter)
        _readerChapters = State(initialValue: chapters)
        _requireOffline = State(initialValue: openingPolicy == .offlineOnly)
        _requestedOnline = State(initialValue: openingPolicy == .onlineOnly)
    }

    var body: some View {
        ZStack {
            if loadingProvider {
                ProgressView("Opening chapter…")
            } else if let providerError {
                ContentUnavailableView {
                    Label("Chapter unavailable", systemImage: "book.closed")
                } description: {
                    Text(providerError)
                } actions: {
                    Button("Retry") { retryID &+= 1 }
                    if model.source(id: sourceID) != nil {
                        Button("Read online") { readOnline() }
                    }
                }
            } else {
                let revision = offlineLease == nil ? model.sourceRevision(for: sourceID) : 0
                ReaderSessionView(
                    mangaTitle: mangaTitle,
                    chapter: $chapter,
                    chapters: readerChapters,
                    sourceID: sourceID,
                    sourceRevision: revision,
                    source: offlineLease == nil ? model.source(id: sourceID) : nil,
                    offlineLease: offlineLease,
                    onReadOnline: readOnline
                )
                .id(offlineLease.map { "offline:\($0.id)" } ?? "online:\(sourceID):\(revision)")
            }
        }
        .task(id: retryID) { await resolveProvider() }
        .onDisappear {
            providerGeneration &+= 1
            let lease = offlineLease
            offlineLease = nil
            Task {
                await lease?.close()
                await model.refreshDownloads()
            }
        }
    }

    private func readOnline() {
        requestedOnline = true
        requireOffline = false
        loadingProvider = true
        retryID &+= 1
    }

    private func resolveProvider() async {
        providerGeneration &+= 1
        let generation = providerGeneration
        loadingProvider = true
        providerError = nil
        let previous = offlineLease
        offlineLease = nil
        await previous?.close()
        defer { if generation == providerGeneration { loadingProvider = false } }
        guard let chapterID = chapter.id else {
            providerError = "This chapter is no longer available."
            return
        }
        do {
            if !requestedOnline {
                let local = try await model.openOfflineChapter(chapterID: chapterID, sourceID: sourceID)
                guard !Task.isCancelled, generation == providerGeneration else {
                    await local?.lease.close()
                    return
                }
                if let local {
                    offlineLease = local.lease
                    chapter = local.chapter
                    readerChapters = local.neighbours
                    requireOffline = true
                    return
                }
                if requireOffline {
                    providerError = "This chapter is not downloaded. Download it when its source is available, or choose Read online."
                    return
                }
            }
            guard model.source(id: sourceID) != nil else {
                providerError = "Source unavailable. Your reading data is saved. Enable this source in Extensions to read online."
                return
            }
        } catch {
            guard !Task.isCancelled, generation == providerGeneration else { return }
            providerError = "Downloaded files are missing, damaged, or unavailable. Retry the local files or re-download this chapter from Downloads."
        }
    }
}

@MainActor
private struct ReaderSessionView: View {
    let mangaTitle: String
    let chapters: [Chapter]
    @Binding private var chapter: Chapter
    let sourceID: Int64
    let sourceRevision: UInt64
    let source: (any KamiSource)?
    let onReadOnline: () -> Void
    private let offlineOnly: Bool

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reader.mode") private var modeRaw = ReaderMode.leftToRight.rawValue
    @AppStorage("reader.background") private var backgroundRaw = ReaderBackground.black.rawValue
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake = true
    @AppStorage("reader.prefetchPages") private var prefetchPages = 3
    @AppStorage("reader.webtoonGap") private var webtoonGap = 0.0

    @StateObject private var imageStore: ReaderImageStore
    @State private var pages: [PageCompat] = []
    @State private var imageRequests: [ImageRequest?] = []
    @State private var currentIndex = 0
    @State private var errorText: String?
    @State private var loading = true
    @State private var showingSettings = false
    @State private var chromeVisible = true
    @State private var previousIdleTimerDisabled: Bool?
    @State private var loadGeneration = 0
    @State private var reloadID = 0
    @State private var pendingStartAtEnd = false
    @State private var progressTask: Task<Void, Never>?
    @State private var offlineLease: OfflineChapterLease?
    @State private var leaseChapterID: Int64?
    @State private var localSessionActive = true

    init(
        mangaTitle: String,
        chapter: Binding<Chapter>,
        chapters: [Chapter] = [],
        sourceID: Int64,
        sourceRevision: UInt64,
        source: (any KamiSource)?,
        offlineLease: OfflineChapterLease?,
        onReadOnline: @escaping () -> Void
    ) {
        self.mangaTitle = mangaTitle
        self.chapters = chapters
        self._chapter = chapter
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.source = source
        self.offlineOnly = offlineLease != nil
        self.onReadOnline = onReadOnline
        _offlineLease = State(initialValue: offlineLease)
        _leaseChapterID = State(initialValue: chapter.wrappedValue.id)
        _imageStore = StateObject(wrappedValue: ReaderImageStore(
            sourceID: "\(sourceID):\(sourceRevision)",
            offlineOnly: offlineLease != nil,
            transportPolicy: source?.transportPolicy
                ?? CompatHTTPTransportPolicy(allowsInsecureHTTP: false)
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
                        if offlineOnly {
                            Text("Offline").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        goToNeighborChapter(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(neighborChapter(-1) == nil)
                    .accessibilityLabel("Previous chapter")

                    Button {
                        goToNeighborChapter(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(neighborChapter(1) == nil)
                    .accessibilityLabel("Next chapter")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if offlineOnly, model.source(id: sourceID) != nil {
                        Button("Read online", action: onReadOnline)
                            .accessibilityHint("Choose online reading for this chapter. This uses its enabled source and a network connection.")
                    }
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
        .task(id: reloadID) { await load() }
        .onAppear {
            localSessionActive = true
            normalizeStoredSettings()
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            applyIdleTimerSetting()
        }
        .onDisappear {
            localSessionActive = false
            loadGeneration &+= 1
            progressTask?.cancel()
            progressTask = nil
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
            imageStore.stop()
            let lease = offlineLease
            offlineLease = nil
            Task {
                await lease?.close()
                await model.refreshDownloads()
            }
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

    private var isSessionCurrent: Bool {
        offlineOnly ? localSessionActive : model.isSourceCurrent(id: sourceID, revision: sourceRevision)
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
                    page: pages[index],
                    source: source,
                    request: imageRequest(at: index),
                    offlineLease: offlineLease,
                    requestGeneration: loadGeneration,
                    store: imageStore,
                    layout: .paged,
                    isActive: abs(index - currentIndex) <= 1,
                    background: backgroundColor,
                    foreground: foregroundColor,
                    onSingleTap: handlePagedTap,
                    onRequestRefresh: imageRequestPublisher(at: index),
                    onReadOnline: offlineOnly && model.source(id: sourceID) != nil ? onReadOnline : nil
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
                                page: pages[index],
                                source: source,
                                request: imageRequest(at: index),
                                offlineLease: offlineLease,
                                requestGeneration: loadGeneration,
                                store: imageStore,
                                layout: .webtoon,
                                isActive: true,
                                background: backgroundColor,
                                foreground: foregroundColor,
                                onSingleTap: { _ in toggleChrome() },
                                onRequestRefresh: imageRequestPublisher(at: index),
                                onReadOnline: offlineOnly && model.source(id: sourceID) != nil ? onReadOnline : nil
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
                reloadID &+= 1
            }
            .buttonStyle(.borderedProminent)
            if offlineOnly, model.source(id: sourceID) != nil {
                Button("Read online", action: onReadOnline).buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private func imageRequest(at index: Int) -> ImageRequest? {
        guard imageRequests.indices.contains(index) else { return nil }
        return imageRequests[index]
    }

    private func imageRequestPublisher(at index: Int) -> @MainActor (ImageRequest?) -> Bool {
        let generation = loadGeneration
        return { request in
            guard !Task.isCancelled,
                  isSessionCurrent,
                  generation == loadGeneration,
                  imageRequests.indices.contains(index) else { return false }
            imageRequests[index] = request
            return true
        }
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
        if currentIndex + 1 < pages.count {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1 }
        } else if let next = neighborChapter(1) {
            goToChapter(next, startAtEnd: false)
        }
    }

    private func retreatPage() {
        if currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex -= 1 }
        } else if let previous = neighborChapter(-1) {
            goToChapter(previous, startAtEnd: true)
        }
    }

    private func neighborChapter(_ offset: Int) -> Chapter? {
        guard let index = chapters.firstIndex(where: {
            $0.id == chapter.id && $0.url == chapter.url
        }) else { return nil }
        let neighbor = chapters.index(index, offsetBy: offset)
        guard chapters.indices.contains(neighbor) else { return nil }
        return chapters[neighbor]
    }

    private func goToNeighborChapter(_ offset: Int) {
        guard let neighbor = neighborChapter(offset) else { return }
        goToChapter(neighbor, startAtEnd: offset < 0)
    }

    private func goToChapter(_ neighbor: Chapter, startAtEnd: Bool) {
        pendingStartAtEnd = startAtEnd
        chapter = neighbor
        reloadID &+= 1
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
        guard isSessionCurrent, !pages.isEmpty, !offlineOnly else { return }
        let indexes = ReaderPrefetchPlan.indexes(
            pageCount: pages.count,
            currentIndex: index,
            ahead: settings.prefetchPages,
            behind: 1
        )
        imageStore.prefetch(indexes.compactMap { imageRequest(at: $0) })
    }

    private func persistProgress(_ page: Int) {
        guard isSessionCurrent, let chapterID = chapter.id else { return }
        let mangaID = chapter.mangaId
        let reachedEnd = !pages.isEmpty && page == pages.count - 1
        chapter.lastPageRead = page
        progressTask?.cancel()
        progressTask = Task {
            guard !Task.isCancelled, isSessionCurrent else { return }
            try? await model.store.updateProgress(chapterId: chapterID, page: page)
            guard !Task.isCancelled, isSessionCurrent else { return }
            try? await model.store.recordHistory(
                mangaId: mangaID,
                chapterId: chapterID
            )
            if reachedEnd, !Task.isCancelled, isSessionCurrent {
                try? await model.store.markRead(true, chapterId: chapterID)
            }
        }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        errorText = nil
        pages = []
        imageRequests = []
        await imageStore.reset()

        guard !Task.isCancelled, isSessionCurrent else { return }
        if offlineOnly {
            await loadOffline(generation: generation)
            return
        }
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
            guard !Task.isCancelled, generation == loadGeneration, isSessionCurrent else { return }
            var loadedImageRequests: [ImageRequest?] = []
            loadedImageRequests.reserveCapacity(loadedPages.count)
            for page in loadedPages {
                try Task.checkCancellation()
                guard isSessionCurrent else { return }
                loadedImageRequests.append(await source.getImageRequest(page: page))
            }
            try Task.checkCancellation()
            guard generation == loadGeneration, isSessionCurrent else { return }
            pages = loadedPages
            imageRequests = loadedImageRequests
            if pendingStartAtEnd {
                currentIndex = max(loadedPages.count - 1, 0)
                pendingStartAtEnd = false
            } else {
                currentIndex = min(chapter.lastPageRead, max(loadedPages.count - 1, 0))
            }
            loading = false
            if loadedPages.isEmpty {
                errorText = "This chapter has no pages."
            } else {
                schedulePrefetch(around: currentIndex)
                persistProgress(currentIndex)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, isSessionCurrent else { return }
            errorText = "Could not load pages: \(error.localizedDescription)"
            loading = false
        }
    }

    private func loadOffline(generation: Int) async {
        do {
            if leaseChapterID != chapter.id || offlineLease == nil {
                let previous = offlineLease
                offlineLease = nil
                await previous?.close()
                guard let chapterID = chapter.id else {
                    errorText = "This chapter is no longer available."
                    loading = false
                    return
                }
                let local = try await model.openOfflineChapter(chapterID: chapterID, sourceID: sourceID)
                guard !Task.isCancelled, generation == loadGeneration, isSessionCurrent else {
                    await local?.lease.close()
                    return
                }
                guard let local else {
                    errorText = "This chapter is not downloaded. Download it when its source is available, or choose Read online."
                    loading = false
                    return
                }
                offlineLease = local.lease
                leaseChapterID = chapterID
                chapter = local.chapter
            }
            guard let offlineLease, !Task.isCancelled,
                  generation == loadGeneration, isSessionCurrent else { return }
            pages = offlineLease.pages.map { PageCompat(index: $0.ordinal) }
            imageRequests = Array(repeating: nil, count: pages.count)
            if pendingStartAtEnd {
                currentIndex = max(pages.count - 1, 0)
                pendingStartAtEnd = false
            } else {
                currentIndex = min(max(chapter.lastPageRead, 0), max(pages.count - 1, 0))
            }
            loading = false
            if pages.isEmpty {
                errorText = "This download has no readable pages. Re-download the chapter from Downloads."
            } else {
                persistProgress(currentIndex)
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, isSessionCurrent else { return }
            errorText = "Downloaded files are missing, damaged, or unavailable. Retry the local files or re-download this chapter from Downloads."
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
