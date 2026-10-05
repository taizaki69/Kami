import SwiftUI
import UniformTypeIdentifiers
import KamiCore
import MihonCompatKit

extension UTType {
    static let kamiLibraryBackup = UTType(exportedAs: "app.kami.library-backup", conformingTo: .json)
}

enum LibraryBackupExportError: Error, LocalizedError {
    case storageUnavailable
    case exportOnly

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Saved storage could not be opened. Reopen Kami before exporting a backup."
        case .exportOnly:
            return "Choose a Kami backup in Library backups to review it before restoring."
        }
    }
}

/// Only validated bytes reach the system exporter. This type advertises no
/// readable content types; opening a file is not a restore operation.
struct LibraryBackupFile: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.kamiLibraryBackup] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        throw LibraryBackupExportError.exportOnly
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PreparedLibraryBackup: Sendable {
    let data: Data
    let exportedAt: Date
    let defaultFilename: String
    let libraryMangaCount: Int
    let otherMangaCount: Int
    let categoryCount: Int
    let chapterCount: Int
    let historyCount: Int
    let unresolvedSourceCount: Int

    init(document: LibraryBackupDocument, data: Data) {
        self.data = data
        exportedAt = Date(timeIntervalSince1970: TimeInterval(document.exportedAt))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        defaultFilename = "Kami-\(formatter.string(from: exportedAt))-\(document.exportID.uuidString.prefix(8))"
        libraryMangaCount = document.manga.filter(\.inLibrary).count
        otherMangaCount = document.manga.count - libraryMangaCount
        categoryCount = document.categories.count
        chapterCount = document.manga.reduce(0) { $0 + $1.chapters.count }
        historyCount = document.manga.reduce(0) { $0 + $1.history.count }
        unresolvedSourceCount = document.sources.filter { $0.contentBinding.kind == .unresolved }.count
    }
}

@MainActor
struct LibraryBackupsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: PreparedLibraryBackup?
    @State private var preparation: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var showingExporter = false
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var showingImporter = false
    @State private var restoreInput: Data?
    @State private var restorePreview: LibraryRestorePreview?
    @State private var restoreFilename: String?
    @State private var excludeConflicts = false
    @State private var preparingRestore = false
    @State private var choosingMihon = false
    @State private var inputIsMihon = false
    @State private var acknowledgeMihon = false

    var body: some View {
        let presentation = model.libraryPresentation.generation
        NavigationStack {
            List {
                Section {
                    Text("Save your library, categories, chapter progress and reading history to a Kami backup file.")
                    Text("Restore a Kami backup, or review supported data from a Mihon backup before importing it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                restoreSection(presentation: presentation)

                if let prepared {
                    Section("Ready to save") {
                        LabeledContent("Created", value: prepared.exportedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Library manga", value: "\(prepared.libraryMangaCount)")
                        LabeledContent("Other saved manga", value: "\(prepared.otherMangaCount)")
                        LabeledContent("Categories", value: "\(prepared.categoryCount)")
                        LabeledContent("Chapters", value: "\(prepared.chapterCount)")
                        LabeledContent("History entries", value: "\(prepared.historyCount)")
                        LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: Int64(prepared.data.count), countStyle: .file))
                        if prepared.unresolvedSourceCount > 0 {
                            Text("\(prepared.unresolvedSourceCount) source addresses could not be identified. Their saved entries are included with this uncertainty recorded.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            saved = false
                            errorMessage = nil
                            showingExporter = true
                        } label: {
                            Label("Save to Files", systemImage: "square.and.arrow.up")
                        }.disabled(operationID != nil)
                    }
                }

                Section {
                    if operationID != nil {
                        HStack {
                            ProgressView()
                            Text(preparingRestore ? "Reviewing backup…" : "Preparing backup…")
                            Spacer()
                            Button("Cancel") { cancelPreparation() }
                        }
                    } else {
                        Button {
                            prepare(expected: presentation)
                        } label: {
                            Label(prepared == nil ? "Prepare backup" : "Prepare a new backup",
                                  systemImage: "externaldrive.badge.plus")
                        }
                    }
                    if saved {
                        Label("Backup saved.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Backup saved")
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Includes all saved manga, including entries outside your library and chapters hidden after a source refresh. Downloaded pages, extension installations and app settings are excluded.")
                }
            }
            .disabled(model.libraryPresentation.isExclusive)
            .safeAreaInset(edge: .bottom) {
                if model.libraryPresentation.isExclusive {
                    HStack {
                        ProgressView("Restoring library…")
                        Spacer()
                        Button("Cancel") { model.cancelLibraryRestore() }
                    }.padding().background(.regularMaterial)
                }
            }
            .navigationTitle("Library backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        cancelPreparation()
                        dismiss()
                    }
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: prepared.map { LibraryBackupFile(data: $0.data) },
                contentType: .kamiLibraryBackup,
                defaultFilename: prepared?.defaultFilename
            ) { result in
                switch result {
                case .success:
                    saved = true
                    errorMessage = nil
                case .failure:
                    saved = false
                    errorMessage = "The backup could not be saved. Try another location in Files."
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.kamiLibraryBackup, .json, .data]) { result in
                switch result {
                case let .success(url): readRestore(url, mihon: choosingMihon, expected: presentation)
                case .failure: errorMessage = "The file could not be opened. Choose a downloaded backup in Files."
                }
            }
            .onDisappear { cancelPreparation() }
            .onChange(of: model.libraryRestoreFailure?.id) { _, _ in
                guard let failure = model.libraryRestoreFailure, failure.previewID == restorePreview?.id else { return }
                restorePreview = nil
                errorMessage = failure.message
            }
        }
    }

    @ViewBuilder
    private func restoreSection(presentation: LibraryPresentationGeneration) -> some View {
        Section {
            Button {
                choosingMihon = false
                showingImporter = true
            } label: {
                Label("Choose a Kami backup", systemImage: "square.and.arrow.down")
            }.disabled(operationID != nil)
            Button {
                choosingMihon = true
                showingImporter = true
            } label: {
                Label("Choose a Mihon backup", systemImage: "square.and.arrow.down")
            }.disabled(operationID != nil)
            if let restoreFilename { Text(restoreFilename).font(.subheadline) }
            if let preview = restorePreview {
                if let report = preview.mihonReport { mihonReview(report, expected: presentation) }
                LabeledContent("New manga", value: "\(preview.summary.newManga)")
                LabeledContent("Existing manga to merge", value: "\(preview.summary.existingManga)")
                LabeledContent("New chapters", value: "\(preview.summary.newChapters)")
                LabeledContent("Existing chapters", value: "\(preview.summary.existingChapters)")
                LabeledContent("New categories", value: "\(preview.summary.newCategories)")
                LabeledContent("History entries to merge", value: "\(preview.summary.historyEntries)")
                if preview.summary.unresolvedManga > 0 {
                    Text("\(preview.summary.unresolvedManga) manga have an unresolved source address. Their saved data will be kept, but source access will remain unavailable.")
                        .font(.footnote)
                }
                let unavailable = preview.sources.filter { model.registry.source(id: $0.sourceID) == nil }
                if !unavailable.isEmpty {
                    DisclosureGroup("Sources not currently enabled (\(unavailable.count))") {
                        ForEach(unavailable, id: \.sourceID) { source in
                            Text("\(source.name.isEmpty ? "Unknown source" : source.name) · \(source.sourceID)")
                                .font(.footnote)
                        }
                    }
                    Text("Saved entries can be restored without enabling their sources. This file will not install extensions or change their settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !preview.conflicts.isEmpty {
                    LabeledContent("Manga with source conflicts", value: "\(preview.summary.excludedManga)")
                    ForEach(preview.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Source \(conflict.sourceID): \(conflict.mangaCount) manga")
                            Text(conflict.reason == .differentDeployment
                                 ? "The saved source address differs from this backup."
                                 : "The source address cannot be matched safely.")
                            if let address = conflict.storedDeployment { Text("Saved address: \(address)") }
                            if let address = conflict.incomingDeployment { Text("Backup address: \(address)") }
                        }.font(.footnote)
                    }
                    Toggle("Exclude manga from conflicting sources", isOn: Binding(
                        get: { excludeConflicts },
                        set: { value in
                            excludeConflicts = value
                            reviewRestore(expected: presentation)
                        }
                    )).disabled(operationID != nil)
                }
                Button(preview.mihonReport != nil ? "Import reviewed supported data"
                       : preview.excludesConflictedSources && !preview.conflicts.isEmpty
                       ? "Restore with these exclusions" : "Restore this backup") {
                    do { try model.beginLibraryRestore(preview, expected: presentation) }
                    catch { errorMessage = error.localizedDescription }
                }.disabled(!preview.canRestore || operationID != nil)
            }
            if restoreInput != nil {
                Button("Review again") { reviewRestore(expected: presentation) }
                    .disabled(operationID != nil)
            }
        } header: {
            Text("Restore from Files")
        } footer: {
            Text("Existing titles and chapter lists are preserved. Read and bookmark flags are combined; page progress and history keep the greater saved values. Imported chapters do not create new Updates. Review again if your library changes before confirmation.")
        }
    }

    @ViewBuilder
    private func mihonReview(_ report: MihonLibraryImportReport, expected: LibraryPresentationGeneration) -> some View {
        Text("Mihon import: MangaDex in English").font(.headline)
        Text("Only the verified MangaDex English source ID and manga/chapter paths are mapped. Other sources and unsupported records are excluded. This does not recreate Mihon's full chapter list or reader settings.")
            .font(.footnote)
        LabeledContent("Manga in file", value: "\(report.inputManga)")
        LabeledContent("Supported manga", value: "\(report.mappedManga)")
        if report.reusedStoredChapters > 0 {
            LabeledContent("Saved chapters matched for history", value: "\(report.reusedStoredChapters)")
        }
        LabeledContent("Excluded manga / chapters / history", value: "\(report.excludedManga) / \(report.excludedChapters) / \(report.excludedHistory)")
        LabeledContent("Unsupported field occurrences", value: "\(report.coverage.unsupportedOccurrences)")
        if !report.issues.isEmpty {
            DisclosureGroup("Exclusion details") {
                ForEach(report.issues) { issue in
                    LabeledContent(exclusionLabel(issue.reason), value: "\(issue.count)")
                }
            }
        }
        if !report.unsupportedSourceIDs.isEmpty {
            DisclosureGroup("Unmapped source IDs (\(report.unsupportedSourceIDs.count))") {
                ForEach(Array(report.unsupportedSourceIDs.prefix(20)), id: \.self) { id in Text(String(id)) }
                if report.unsupportedSourceIDs.count > 20 { Text("Showing the first 20 IDs.") }
            }
        }
        if !report.coverage.unsupported.isEmpty {
            DisclosureGroup("Unsupported fields") {
                ForEach(Array(report.coverage.unsupported.enumerated()), id: \.offset) { _, item in
                    Text("\(coverageLabel(item.feature)) (\(String(describing: item.scope))): \(item.occurrences)")
                        .font(.footnote)
                }
            }
        }
        if report.duplicateManga + report.duplicateChapters + report.duplicateHistory > 0 {
            Text("Duplicate manga/chapter/history records merged: \(report.duplicateManga) / \(report.duplicateChapters) / \(report.duplicateHistory). First metadata is kept; read/bookmark flags are combined and greater progress/history values are retained.")
                .font(.footnote)
        }
        if report.roundedTimestamps > 0 || report.normalizedCategories > 0 {
            Text("\(report.roundedTimestamps) timestamps rounded down to whole seconds; \(report.normalizedCategories) category names trimmed.").font(.footnote)
        }
        Text("Keep your original backup. Excluded records and unsupported fields are not saved in Kami. Native MangaDex refreshes may hide alternate chapter editions while preserving their progress and history.")
            .font(.footnote).foregroundStyle(.secondary)
        Toggle("Import only the supported data reviewed above", isOn: Binding(
            get: { acknowledgeMihon },
            set: { acknowledgeMihon = $0; reviewRestore(expected: expected) }
        )).disabled(operationID != nil || !report.hasImportableData)
        if !report.hasImportableData { Text("This file has no supported manga to import.").font(.footnote) }
    }

    private func exclusionLabel(_ reason: MihonLibraryImportReport.Exclusion) -> String {
        switch reason {
        case .unsupportedSource: "Manga from unmapped sources"
        case .mangaURL: "Manga with unsupported URLs"
        case .chapterURL: "Chapters with unsupported URLs"
        case .chapterParent: "Chapters claimed by multiple manga"
        case .historyReference: "History without an unambiguous chapter"
        case .removedHistory: "History already removed in Mihon"
        case .categoryReference: "Missing category references"
        case .nonLibraryMembership: "Category links on nonlibrary manga"
        }
    }

    private func coverageLabel(_ feature: TachibkReader.UnsupportedFeature) -> String {
        switch feature {
        case .appPreferences: "App preferences"
        case .sourcePreferences: "Source preferences"
        case .extensionStores: "Extension repositories"
        case .tracking: "Tracking services"
        case .readerSettings: "Reader settings"
        case .chapterSettings: "Chapter settings"
        case .excludedScanlators: "Excluded scanlators"
        case .notes: "Notes"
        case .mangaMemo: "Manga annotations"
        case .chapterMemo: "Chapter annotations"
        case .synchronizationMetadata: "Synchronization metadata"
        case .legacySources: "Legacy source records"
        case .legacyHistory: "Legacy history"
        case .unknownField: "Unrecognized fields"
        }
    }

    private func readRestore(_ url: URL, mihon: Bool, expected: LibraryPresentationGeneration) {
        guard operationID == nil else { return }
        let id = UUID()
        operationID = id
        preparingRestore = true
        restorePreview = nil
        restoreInput = nil
        restoreFilename = nil
        excludeConflicts = false
        acknowledgeMihon = false
        errorMessage = nil
        preparation = model.performLibraryOperation(expected: expected) {
            do {
                let bytes = try await model.readLibraryRestoreFile(url, mihon: mihon)
                let preview = try await model.previewLibraryRestore(bytes, excludeConflicts: false, mihon: mihon)
                guard operationID == id, !Task.isCancelled else { return }
                restoreInput = bytes
                inputIsMihon = mihon
                restoreFilename = url.lastPathComponent
                restorePreview = preview
            } catch is CancellationError {} catch {
                guard operationID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard operationID == id else { return }
            operationID = nil
            preparation = nil
        }
        if preparation == nil { operationID = nil }
    }

    private func reviewRestore(expected: LibraryPresentationGeneration) {
        guard operationID == nil, let data = restoreInput else { return }
        let id = UUID()
        operationID = id
        preparingRestore = true
        restorePreview = nil
        errorMessage = nil
        let excluded = excludeConflicts
        let mihon = inputIsMihon, acknowledged = acknowledgeMihon
        preparation = model.performLibraryOperation(expected: expected) {
            do {
                let preview = try await model.previewLibraryRestore(data, excludeConflicts: excluded,
                    mihon: mihon, acknowledgesLimitations: acknowledged)
                guard operationID == id, !Task.isCancelled else { return }
                restorePreview = preview
            } catch is CancellationError {} catch {
                guard operationID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard operationID == id else { return }
            operationID = nil
            preparation = nil
        }
        if preparation == nil { operationID = nil }
    }

    private func prepare(expected: LibraryPresentationGeneration) {
        guard operationID == nil else { return }
        let id = UUID()
        operationID = id
        preparingRestore = false
        prepared = nil
        saved = false
        errorMessage = nil
        preparation = model.performLibraryOperation(expected: expected) {
            do {
                let backup = try await model.prepareLibraryBackup()
                guard operationID == id, !Task.isCancelled else { return }
                prepared = backup
            } catch is CancellationError {
                // A cancelled or dismissed preparation publishes no bytes.
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "The backup could not be prepared. Please try again."
            }
            guard operationID == id else { return }
            operationID = nil
            preparation = nil
        }
        if preparation == nil { operationID = nil }
    }

    private func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
        operationID = nil
    }
}
