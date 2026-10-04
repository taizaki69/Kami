import SwiftUI
import UniformTypeIdentifiers
import KamiCore

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
            return "Restoring library backups is not available in this version."
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

    var body: some View {
        let presentation = model.libraryPresentation.generation
        NavigationStack {
            List {
                Section {
                    Text("Save your library, categories, chapter progress and reading history to a Kami backup file.")
                    Text("Restoring backups is not available in this version.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

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
                        }
                    }
                }

                Section {
                    if operationID != nil {
                        HStack {
                            ProgressView()
                            Text("Preparing backup…")
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
            .onDisappear { cancelPreparation() }
        }
    }

    private func prepare(expected: LibraryPresentationGeneration) {
        guard operationID == nil else { return }
        let id = UUID()
        operationID = id
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
