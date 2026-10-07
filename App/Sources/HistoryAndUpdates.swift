import SwiftUI
import KamiCore

struct LibraryUpdateChapterGroup: Identifiable {
    let id: String
    let day: Date
    let manga: Manga
    let discoveries: [LibraryChapterDiscovery]

    static func group(_ discoveries: [LibraryChapterDiscovery]) -> [Self] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: discoveries) { discovery in
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(discovery.detectedAt)))
            return "\(day.timeIntervalSince1970):\(discovery.manga.id ?? 0)"
        }
        return grouped.compactMap { key, values in
            guard let first = values.first else { return nil }
            return Self(id: key,
                day: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(first.detectedAt))),
                manga: first.manga,
                discoveries: values.sorted {
                    if $0.chapter.sourceOrder != $1.chapter.sourceOrder {
                        return $0.chapter.sourceOrder < $1.chapter.sourceOrder
                    }
                    return $0.id < $1.id
                })
        }.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            let order = $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

private struct ChapterReadingRoute: Hashable {
    let manga: Manga
    let chapterID: Int64
    let chapterURL: String
    let presentation: LibraryPresentationGeneration
}

@MainActor
struct UpdatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAutomaticUpdates = false
    @State private var showingNotifications = false

    var body: some View {
        let presentation = model.libraryPresentation
        NavigationStack {
            List {
                checkSection
                if let summary { summarySection(summary) }
                if let error = model.libraryUpdatesError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Reload saved results") {
                            model.performLibraryOperation(expected: presentation.generation) { await model.refreshLibraryUpdates() }
                        }
                    }
                }
                if model.libraryUpdateGroups.isEmpty {
                    Section {
                        ContentUnavailableView(emptyTitle, systemImage: "books.vertical",
                                               description: Text(emptyDescription))
                    }
                } else {
                    ForEach(model.libraryUpdateGroups) { group in
                        Section {
                            ForEach(group.discoveries) { discovery in
                                ChapterReadingLink(manga: discovery.manga, chapter: discovery.chapter,
                                                   presentation: presentation.generation)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dayLabel(group.day))
                                Text(group.manga.title)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if model.libraryUpdatesHasMore || model.libraryUpdatesPaginationError != nil {
                    Section {
                        if let error = model.libraryUpdatesPaginationError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if model.libraryUpdatesLoadingMore {
                            ProgressView("Loading more saved chapters…")
                        } else if model.libraryUpdatesHasMore {
                            Button("Load more saved chapters") {
                                model.performLibraryOperation(expected: presentation.generation) { await model.loadMoreLibraryUpdates() }
                            }
                            .disabled(model.libraryUpdatesLoading)
                        }
                    }
                }
                issuesSection
            }
            .navigationTitle("Updates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chapter notifications", systemImage: "bell") { showingNotifications = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Automatic updates", systemImage: "clock.arrow.2.circlepath") { showingAutomaticUpdates = true }
                }
            }
            .sheet(isPresented: $showingAutomaticUpdates) { AutomaticUpdatesSettingsView() }
            .sheet(isPresented: $showingNotifications) { ChapterNotificationsSettingsView() }
            .refreshable { await model.runLibraryOperation(expected: presentation.generation) { await model.checkLibraryForUpdates() } }
            .navigationDestination(for: ChapterReadingRoute.self) { route in
                PersistedChapterReaderDestination(manga: route.manga, chapterID: route.chapterID,
                                                 chapterURL: route.chapterURL, presentation: route.presentation)
            }
            .task(id: presentation) {
                guard !presentation.isExclusive else { return }
                await model.runLibraryOperation(expected: presentation.generation) { await model.refreshLibraryUpdates() }
            }
        }
    }

    private var summary: LibraryUpdateSummary? {
        if model.libraryUpdateIsRunning { return model.libraryUpdateProgress?.summary }
        if model.libraryUpdatesError != nil {
            return model.libraryUpdateProgress?.summary ?? model.libraryUpdatesSnapshot?.latestScan
        }
        return model.libraryUpdatesSnapshot?.latestScan
    }

    private var loadingFinishedResults: Bool { model.libraryUpdateProgress?.phase == .finished }

    private var checkSection: some View {
        let presentation = model.libraryPresentation
        return Section {
            if model.libraryUpdateIsRunning {
                HStack {
                    ProgressView()
                    Text(loadingFinishedResults ? "Loading saved results…"
                         : model.libraryUpdateIsCancelling ? "Cancelling check…" : "Checking your library…")
                }
                Text(loadingFinishedResults ? "The check has finished. Loading its saved results."
                     : model.libraryUpdateIsCancelling
                     ? "Waiting for pending requests to stop. Results already saved will be kept."
                     : "You can leave this screen while the check runs.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !loadingFinishedResults {
                    Button(model.libraryUpdateIsCancelling ? "Cancelling…" : "Cancel check", role: .cancel) {
                        model.cancelLibraryUpdate()
                    }
                    .disabled(model.libraryUpdateIsCancelling)
                }
            } else {
                Text(checkTitle).font(.headline)
                Text(checkDescription).font(.footnote).foregroundStyle(.secondary)
                Button("Check for updates") {
                    model.performLibraryOperation(expected: presentation.generation) { await model.checkLibraryForUpdates() }
                }
                .buttonStyle(.borderedProminent)
            }
            if model.libraryUpdatesLoading && model.libraryUpdatesSnapshot == nil {
                ProgressView("Loading saved updates…")
            }
        }
    }

    private func summarySection(_ summary: LibraryUpdateSummary) -> some View {
        Section {
            if model.libraryUpdateIsRunning {
                ProgressView(value: Double(summary.processedCount), total: Double(max(summary.total, 1)))
                    .accessibilityLabel("Library check progress")
                    .accessibilityValue("\(summary.processedCount) of \(summary.total) manga processed")
                Text("\(summary.processedCount) of \(summary.total) manga processed").font(.caption)
                if let progress = model.libraryUpdateProgress {
                    Text("\(progress.inFlight) in progress · \(progress.queued) waiting")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { statistic("Checked", summary.checked); statistic("New chapters", summary.newChapters) }
                GridRow { statistic("First checks", summary.baselines); statistic("Skipped", summary.skipped) }
                GridRow { statistic("Failed", summary.failed); statistic("Cancelled", summary.cancelled) }
            }
            .frame(maxWidth: .infinity)
            if !model.libraryUpdateIsRunning {
                HStack(spacing: 4) {
                    Text("Last check")
                    Text(Date(timeIntervalSince1970: TimeInterval(summary.finishedAt ?? summary.startedAt)), style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statistic(_ name: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(value)")
    }

    @ViewBuilder
    private var issuesSection: some View {
        if let snapshot = model.libraryUpdatesSnapshot, !snapshot.latestScanIssues.isEmpty {
            Section {
                if model.libraryUpdateIsRunning && snapshot.latestScan?.scanID != model.libraryUpdateProgress?.scanID {
                    Text("From the previous saved check").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.latestScanIssues, id: \.mangaID) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(.subheadline)
                        Label(issueDescription(issue.reason, status: snapshot.latestScan?.status), systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Not checked")
            }
        }
    }

    private func issueDescription(_ reason: LibraryUpdateTargetReason, status: LibraryUpdateScanStatus?) -> String {
        switch reason {
        case .sourceUnavailable: return "Source unavailable. Review Extensions before checking again."
        case .configurationChanged: return "Source settings changed or are unavailable. Review Extensions, then check again."
        case .onlyFetchOnce: return "This manga is set to check once."
        case .requestFailed: return "The source request failed. Try checking again."
        case .removedFromLibrary: return "Removed from the library while the check was running."
        case .cancelled:
            return status == .interrupted
                ? "Not checked because the previous check was interrupted."
                : "Not checked because the check was cancelled."
        }
    }

    private var checkTitle: String {
        guard let summary else {
            return model.libraryUpdatesSnapshot == nil ? "Library updates" : "Library not checked yet"
        }
        switch summary.status {
        case .running: return "Previous check incomplete"
        case .interrupted: return "Previous check interrupted"
        case .cancelled: return "Check cancelled"
        case .completed:
            if summary.failed > 0 { return "Check finished with errors" }
            if summary.skipped > 0 { return "Check finished with skipped manga" }
            return summary.newChapters == 0 ? "Check complete · no new chapters" : "Check complete"
        }
    }

    private var checkDescription: String {
        guard let summary else {
            return "Check your library when you're ready. The first successful check for each manga sets its starting point; older chapters are not reported as new."
        }
        switch summary.status {
        case .running, .interrupted:
            return "The previous check did not finish. Its saved results are kept. Check again to review the rest of your library."
        case .cancelled:
            return "Results saved before cancellation are kept. Check again when you're ready."
        case .completed:
            if summary.failed > 0 || summary.skipped > 0 {
                return "Some manga were not checked. Review the reasons below; results from successful checks are saved."
            }
            if summary.baselines > 0 {
                return "First checks set the starting point for those manga without reporting all their older chapters. Future checks will find newly added chapters."
            }
            return "Newly discovered chapters are saved below. Pull to check again."
        }
    }

    private var emptyTitle: String {
        if model.libraryUpdateIsRunning { return loadingFinishedResults ? "Loading saved chapters" : "Checking for new chapters" }
        if model.libraryUpdatesSnapshot == nil { return model.libraryUpdatesLoading ? "Loading updates" : "Updates unavailable" }
        return summary == nil ? "No checks yet" : "No saved new chapters"
    }

    private var emptyDescription: String {
        if model.libraryUpdateIsRunning { return "Saved discoveries will appear here when this check finishes." }
        if model.libraryUpdatesSnapshot == nil { return "Reload saved results or start a manual check." }
        return "Detected chapters from manga in your library appear here, grouped by day and manga."
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct HistoryReadingEntry: Identifiable {
    let manga: Manga
    let chapter: Chapter
    let lastRead: Int64
    var id: Int64 { chapter.id ?? 0 }
}

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [HistoryReadingEntry] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var reloadGeneration: UInt64 = 0

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        let presentation = model.libraryPresentation
        NavigationStack {
            List {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry") { model.performLibraryOperation(expected: presentation.generation) { await reload() } }
                    }
                }
                ForEach(entries) { entry in
                    ChapterReadingLink(manga: entry.manga, chapter: entry.chapter,
                        presentation: presentation.generation,
                        lastRead: Self.formatter.localizedString(
                            for: Date(timeIntervalSince1970: TimeInterval(entry.lastRead)), relativeTo: Date()),
                        showManga: true)
                }
                if entries.isEmpty && errorText == nil {
                    if loading {
                        ProgressView("Loading history…")
                    } else {
                        ContentUnavailableView("No reading history", systemImage: "clock.arrow.circlepath",
                            description: Text("Chapters you read appear here so you can pick up where you left off."))
                    }
                }
            }
            .navigationTitle("History")
            .refreshable { await model.runLibraryOperation(expected: presentation.generation) { await reload() } }
            .navigationDestination(for: ChapterReadingRoute.self) { route in
                PersistedChapterReaderDestination(manga: route.manga, chapterID: route.chapterID,
                                                 chapterURL: route.chapterURL, presentation: route.presentation)
            }
            .task(id: presentation) {
                guard !presentation.isExclusive else { return }
                await model.runLibraryOperation(expected: presentation.generation) { await reload() }
            }
            .onDisappear {
                reloadGeneration &+= 1
            }
        }
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        loading = true
        defer { if generation == reloadGeneration { loading = false } }
        do {
            let history = try await model.store.history()
            await model.refreshDownloadAvailability(chapterIDs: history.compactMap { $0.1.id })
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            entries = history.compactMap { manga, chapter, date in
                guard manga.id != nil, chapter.id != nil else { return nil }
                return HistoryReadingEntry(manga: manga, chapter: chapter, lastRead: date)
            }
            errorText = nil
        } catch {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            errorText = "Reading history could not be loaded. Please try again."
        }
    }
}

@MainActor
private struct ChapterReadingLink: View {
    @EnvironmentObject private var model: AppModel
    let manga: Manga
    let chapter: Chapter
    let presentation: LibraryPresentationGeneration
    var lastRead: String?
    var showManga = false

    var body: some View {
        if let chapterID = chapter.id {
            NavigationLink(value: ChapterReadingRoute(manga: manga, chapterID: chapterID,
                                                     chapterURL: chapter.url, presentation: presentation)) {
                HStack(spacing: 12) {
                    if showManga {
                        CoverImage(url: manga.thumbnailURL, cornerRadius: 4).frame(width: 36, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if showManga { Text(manga.title).lineLimit(2) }
                        Text(chapter.name).font(showManga ? .caption : .body)
                        if isDownloaded {
                            Label("Downloaded · read offline", systemImage: "arrow.down.circle.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if sourceAvailable {
                            Text("Read online").font(.caption).foregroundStyle(.secondary)
                        }
                        if !sourceAvailable {
                            Label("Source unavailable", systemImage: "pause.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let lastRead { Text(lastRead).font(.caption2).foregroundStyle(.secondary) }
                    if chapter.read { Image(systemName: "checkmark").accessibilityLabel("Read") }
                }
            }
            .disabled(!sourceAvailable && !isDownloaded)
            .accessibilityLabel(readingLabel)
            .accessibilityHint(isDownloaded
                               ? "Read this downloaded chapter without a network connection."
                               : sourceAvailable
                               ? "Continue reading this chapter from your saved progress."
                               : "Review this source in Extensions to continue reading.")
        }
    }

    private var sourceAvailable: Bool { model.source(id: manga.sourceId) != nil }
    private var isDownloaded: Bool { chapter.id.map { model.isChapterDownloaded($0) } ?? false }

    private var readingLabel: String {
        var parts = [manga.title, chapter.name]
        if isDownloaded { parts.append("Downloaded, read offline") }
        if chapter.read { parts.append("Read") }
        if let lastRead { parts.append(lastRead) }
        if !sourceAvailable { parts.append("Source unavailable") }
        return parts.joined(separator: ". ")
    }
}
