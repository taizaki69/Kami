import SwiftUI
import KamiCore

private struct DownloadReadingRoute: Hashable {
    let manga: Manga
    let chapterID: Int64
}

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Download chapters to read without a connection.")
                    Text("Downloads run while the app is active. Interrupted chapters can be retried from the beginning.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.downloadQueueIsRunning {
                        HStack {
                            ProgressView()
                            Text(model.downloadQueueIsPausing ? "Pausing downloads…" : "Downloading chapters…")
                        }
                        Button(model.downloadQueueIsPausing ? "Pausing…" : "Pause queue") {
                            Task { await model.pauseDownloads() }
                        }
                        .disabled(model.downloadQueueIsPausing)
                    } else if (model.downloadsSummary?.queued ?? 0) > 0 {
                        Button("Start queued downloads") { Task { await model.startDownloads() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let summary = model.downloadsSummary {
                    Section {
                        Grid(horizontalSpacing: 20, verticalSpacing: 10) {
                            GridRow { statistic("Queued", summary.queued); statistic("Active", summary.active) }
                            GridRow { statistic("Downloaded", summary.finished); statistic("Failed", summary.failed) }
                            GridRow { statistic("Paused", summary.paused); statistic("Cancelled", summary.cancelled) }
                        }
                        .frame(maxWidth: .infinity)
                        Text("Downloaded page data: \(DownloadPresentation.bytes(summary.storedBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Download storage limit: \(DownloadPresentation.bytes(summary.quotaBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        if summary.deleting > 0 || summary.cleanupBytes > 0 {
                            Text("Removal pending: \(summary.deleting) chapters · \(DownloadPresentation.bytes(summary.cleanupBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.downloadsError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Reload downloads") { Task { await model.refreshDownloads() } }
                    }
                }
                if let item = activeDownload {
                    Section("Current download") {
                        downloadDescription(item)
                        ChapterDownloadControls(manga: item.manga, chapter: item.chapter,
                                                inLibrary: item.manga.inLibrary)
                    }
                }
                ForEach(model.downloads) { item in
                    downloadRow(item)
                }
                if model.downloads.isEmpty && model.downloadsError == nil {
                    Section {
                        if model.downloadsLoading {
                            ProgressView("Loading saved downloads…")
                        } else {
                            ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                description: Text("Open a manga in your library and download a chapter. Downloaded chapters remain here until you remove them."))
                        }
                    }
                }
                if model.downloadsHasMore || model.downloadsPaginationError != nil {
                    Section {
                        if let error = model.downloadsPaginationError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if model.downloadsLoadingMore {
                            ProgressView("Loading more downloads…")
                        } else if model.downloadsHasMore {
                            Button("Load more downloads") { Task { await model.loadMoreDownloads() } }
                                .disabled(model.downloadsLoading)
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .navigationDestination(for: DownloadReadingRoute.self) { route in
                PersistedChapterReaderDestination(manga: route.manga, chapterID: route.chapterID,
                                                 openingPolicy: .offlineOnly)
            }
            .refreshable { await model.refreshDownloads() }
            .onAppear {
                refreshTask?.cancel()
                refreshTask = Task { await model.refreshDownloads() }
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
            }
        }
    }

    private var activeDownload: DownloadItem? {
        guard model.downloadQueueIsRunning, let progress = model.downloadProgress,
              let item = progress.item, progress.activeJobID == item.jobID else { return nil }
        return item
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        Section {
            downloadDescription(item)
            if item.state == .finished, let chapterID = item.chapter.id {
                NavigationLink("Read offline", value: DownloadReadingRoute(manga: item.manga, chapterID: chapterID))
                    .accessibilityHint("Read this downloaded chapter without using its source or a network connection.")
            }
            ChapterDownloadControls(manga: item.manga, chapter: item.chapter,
                                    inLibrary: item.manga.inLibrary)
        }
    }

    private func downloadDescription(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.manga.title).font(.headline)
            Text(item.chapter.name)
            if !item.isCurrentChapter {
                Text("Saved chapter · no longer in the source's current list")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(DownloadPresentation.title(state: item.state, reason: item.reason))
                .font(.subheadline).foregroundStyle(.secondary)
            if item.state == .downloading {
                if let total = item.pageCount {
                    ProgressView(value: Double(item.completedPages), total: Double(max(total, 1)))
                        .accessibilityLabel("Chapter download progress")
                        .accessibilityValue("\(item.completedPages) of \(total) pages")
                    Text("\(item.completedPages) of \(total) pages")
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView("Preparing chapter…")
                }
            } else if item.state == .finished, let total = item.pageCount {
                Text("\(total) pages · \(DownloadPresentation.bytes(item.storedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statistic(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

enum DownloadPresentation {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    static func title(state: DownloadState, reason: DownloadFailureReason?) -> String {
        switch state {
        case .queued: return "Waiting in queue"
        case .downloading: return "Downloading"
        case .finished: return "Downloaded · available offline"
        case .failed: return "Download failed"
        case .paused: return reason == .interrupted ? "Previous download interrupted" : "Download paused"
        case .cancelled: return "Download cancelled"
        case .deleting: return "Removal pending"
        }
    }

    static func message(_ reason: DownloadFailureReason) -> String {
        switch reason {
        case .sourceUnavailable: return "Enable this source in Extensions before downloading. Already downloaded chapters remain available."
        case .configurationChanged: return "Source settings changed. Review Extensions, then retry this chapter."
        case .mangaRemoved: return "This manga is no longer in your library. Add it again before downloading."
        case .chapterUnavailable: return "This chapter is no longer available for download."
        case .pageListInvalid: return "The source did not provide a usable chapter page list."
        case .imageRequestUnavailable: return "The source did not provide a valid request for a page."
        case .imageInvalid: return "A page response is not a supported image. Retry the chapter."
        case .transferFailed: return "A page could not be downloaded. Check your connection and retry."
        case .quotaExceeded: return "Downloads have reached the storage limit. Remove a download before retrying."
        case .diskSpaceLow: return "There is not enough free space on this device. Free some space before retrying."
        case .storageUnavailable: return "Download files could not be saved or removed. Please try again."
        case .bundleCorrupt: return "Downloaded files are missing or damaged. Re-download the chapter when its source is available."
        case .legacyUnverified: return "This older download needs to be downloaded again before it can be read offline."
        case .interrupted: return "The previous download did not finish. Retry starts this chapter from the beginning."
        case .paused: return "Retry starts this chapter from the beginning."
        case .cancelled: return "Retry starts this chapter from the beginning."
        }
    }
}

@MainActor
struct ChapterDownloadControls: View {
    @EnvironmentObject private var model: AppModel
    let manga: Manga
    let chapter: Chapter
    let inLibrary: Bool
    @State private var confirmRemoval = false

    var body: some View {
        if let chapterID = chapter.id {
            VStack(alignment: .leading, spacing: 6) {
                if let state = model.downloadState(for: chapterID) {
                    if let reason = state.reason {
                        Text(DownloadPresentation.message(reason)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.downloadCancellingJobs.contains(state.jobID) {
                        ProgressView("Cancelling download…")
                        Text("Waiting for pending requests to stop.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        switch state.state {
                        case .queued, .downloading:
                            Button("Cancel download", role: .cancel) { Task { await model.cancelDownload(jobID: state.jobID) } }
                        case .finished:
                            Button("Delete download", role: .destructive) { confirmRemoval = true }
                        case .paused, .failed, .cancelled:
                            Button("Retry download") { Task { await model.retryDownload(jobID: state.jobID) } }
                                .disabled(!sourceAvailable || !inLibrary)
                            if !inLibrary {
                                Text("Add this manga to your library before downloading.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if !sourceAvailable {
                                Text("Enable this source in Extensions to download. Saved reading data is kept.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Delete download", role: .destructive) { confirmRemoval = true }
                        case .deleting:
                            Text("Close this chapter if it is open. Its files will be removed when reading finishes.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Retry removal") { Task { await model.deleteDownload(jobID: state.jobID) } }
                        }
                    }
                    if model.downloadBusyJobs.contains(state.jobID) && !model.downloadCancellingJobs.contains(state.jobID) {
                        ProgressView("Updating download…")
                    }
                } else {
                    Button("Download chapter") { Task { await model.enqueueDownload(chapterID: chapterID) } }
                        .disabled(!sourceAvailable || !inLibrary || model.downloadBusyChapters.contains(chapterID))
                    if !inLibrary {
                        Text("Add this manga to your library before downloading.").font(.caption).foregroundStyle(.secondary)
                    } else if !sourceAvailable {
                        Text("Enable this source in Extensions before downloading.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.downloadOperationErrors[chapterID] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
            }
            .disabled(model.downloadBusyChapters.contains(chapterID)
                      || model.downloadState(for: chapterID).map { model.downloadBusyJobs.contains($0.jobID) } == true)
            .confirmationDialog("Delete this download?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                if let state = model.downloadState(for: chapterID) {
                    Button("Delete download", role: .destructive) { Task { await model.deleteDownload(jobID: state.jobID) } }
                }
                Button("Keep download", role: .cancel) {}
            } message: {
                Text("Remove downloaded files for \(manga.title) · \(chapter.name). Your library, reading progress and history will be kept.")
            }
        }
    }

    private var sourceAvailable: Bool { model.source(id: manga.sourceId) != nil }
}
