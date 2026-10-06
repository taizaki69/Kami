import SwiftUI
import UniformTypeIdentifiers
import MihonCompatKit
import KamiCore

/// Immutable, bounded bytes prepared from a runtime report. Reading a text
/// file here does not import diagnostics or grant any execution authority.
struct CompatibilityReportFile: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.plainText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw SourceCompatibilityDiagnosticsError.unavailable }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct CompatibilityDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    let presentation: LibraryPresentationGeneration

    var body: some View {
        let registrations = model.readySourceRegistrations().filter {
            $0.source is any InterpretedCompatibilityReportingSource
        }
        List {
            Section {
                Text("Inspect compatibility gaps recorded while using an enabled extension, then choose whether to save a report.")
                Text("Reports contain package/version and unsupported runtime symbols. They exclude browsing queries, request contents and library data. Nothing is sent automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Enabled extensions") {
                ForEach(registrations, id: \.registrationID) { registration in
                    NavigationLink {
                        SourceCompatibilityReportView(registration: registration, presentation: presentation)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(registration.source.name)
                            Text(registration.source.language).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if registrations.isEmpty {
                    Text("No enabled extension has a runtime report available. Native sources do not collect these reports.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Reports cover this source instance in the current app session. Restarting, disabling or replacing a source clears that instance. No recorded gap does not mean every operation is compatible; network and parsing errors are outside this report.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Compatibility diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct SourceCompatibilityReportView: View {
    @EnvironmentObject private var model: AppModel
    let registration: SourceRegistrationSnapshot
    let presentation: LibraryPresentationGeneration
    @State private var prepared: SourceCompatibilityReport?
    @State private var worker: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var cancelling = false
    @State private var showingExporter = false
    @State private var exporting: CompatibilityReportFile?
    @State private var message: String?
    @State private var saved = false

    private var isCurrent: Bool {
        model.isSourceCurrent(id: registration.sourceID, revision: registration.revision)
            && model.readySourceRegistrations().contains { $0.registrationID == registration.registrationID }
    }

    var body: some View {
        List {
            if !isCurrent {
                Section {
                    Label("Source changed. Go back to choose its current report.", systemImage: "arrow.clockwise")
                }
            } else if let prepared {
                reportSections(prepared.export)
            } else if operationID != nil {
                Section {
                    ProgressView(cancelling ? "Cancelling report…" : "Preparing report…")
                    Button("Cancel") { cancelPreparation() }.disabled(cancelling)
                }
            }
            if let message {
                Section { Label(message, systemImage: "info.circle").font(.footnote) }
            }
            if saved { Section { Label("Report saved.", systemImage: "checkmark.circle").foregroundStyle(.green) } }
        }
        .navigationTitle(registration.source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { prepare() } label: { Label("Refresh report", systemImage: "arrow.clockwise") }
                    .disabled(!isCurrent || operationID != nil || showingExporter)
            }
        }
        .onAppear { if prepared == nil { prepare() } }
        .onDisappear { cancelPreparation() }
        .onChange(of: model.sourceGeneration) { _, _ in invalidateIfNeeded() }
        .onChange(of: model.extensionBusyPackages) { _, _ in invalidateIfNeeded() }
        .fileExporter(isPresented: $showingExporter, document: exporting,
                      contentType: .plainText, defaultFilename: "Kami-compatibility-report") { result in
            exporting = nil
            guard isCurrent else { return }
            switch result {
            case .success:
                saved = true
                message = nil
            case let .failure(error):
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                    message = "The report could not be saved. Try another location in Files."
                }
            }
        }
    }

    @ViewBuilder
    private func reportSections(_ exported: InterpretedCompatibilityExport) -> some View {
        Section("Report snapshot") {
            LabeledContent("Package", value: exported.report.packageName)
            LabeledContent("Version", value: "\(exported.report.versionName) (\(exported.report.versionCode))")
            LabeledContent("Gaps included", value: "\(exported.report.findings.count) of \(exported.capturedFindingCount)")
            LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: Int64(exported.data.count), countStyle: .file))
            if exported.omittedFindingCount > 0 {
                Text("\(exported.omittedFindingCount) distinct gaps were omitted to keep the file bounded (\(exported.exportOmittedOccurrences) occurrences).")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if exported.recorderDroppedOccurrences > 0 {
                Text("The runtime recorder could not retain \(exported.recorderDroppedOccurrences) additional occurrences.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button {
                guard isCurrent else { return }
                exporting = CompatibilityReportFile(data: exported.data)
                saved = false
                message = nil
                showingExporter = true
            } label: {
                Label("Save report to Files", systemImage: "square.and.arrow.up")
            }.disabled(operationID != nil || showingExporter)
            Text("Only this snapshot is saved. Refresh to include newly recorded gaps. Reports are local and are not attached to an issue automatically.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Recorded gaps") {
            if exported.report.findings.isEmpty {
                Text(exported.report.hasFindings ? "No individual gaps were retained."
                     : "No compatibility gaps have been recorded for this source instance.")
                Text("This is not proof of complete compatibility. Network and parsing errors are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(exported.report.findings.indices, id: \.self) { index in
                let finding = exported.report.findings[index]
                NavigationLink {
                    List {
                        LabeledContent("Operation", value: finding.stage.rawValue)
                        LabeledContent("Kind", value: finding.surface.kind)
                        LabeledContent("Occurrences", value: "\(finding.occurrences)")
                        Text(finding.surface.summary).font(.footnote.monospaced()).textSelection(.enabled)
                    }.navigationTitle("Compatibility gap").navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(finding.stage.rawValue) · \(finding.surface.kind) · \(finding.occurrences) occurrences")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(finding.surface.summary).font(.footnote.monospaced()).lineLimit(3)
                    }
                }
            }
        }
    }

    private func prepare() {
        guard isCurrent, operationID == nil else { return }
        let token = UUID()
        operationID = token
        cancelling = false
        prepared = nil
        message = nil
        saved = false
        let admitted = model.performLibraryOperation(expected: presentation) {
            do {
                let result = try await model.prepareCompatibilityReport(registration: registration)
                guard !Task.isCancelled, operationID == token, isCurrent else { return }
                prepared = result
            } catch is CancellationError {
                // A dismissed or obsolete report cannot publish new bytes.
            } catch {
                guard !Task.isCancelled, operationID == token, isCurrent else { return }
                message = "The compatibility report could not be prepared. Please try again."
            }
        }
        worker = admitted
        guard let admitted else { operationID = nil; return }
        // Observe the owner even if cancellation prevents its operation
        // closure from starting. Cleanup inside that closure would be skipped.
        Task { @MainActor in
            await admitted.value
            guard operationID == token else { return }
            operationID = nil
            worker = nil
            cancelling = false
        }
    }

    private func cancelPreparation() {
        guard operationID != nil else { return }
        cancelling = true
        worker?.cancel()
        // Keep admission closed until the snapshot worker actually drains.
    }

    private func invalidateIfNeeded() {
        guard !isCurrent else { return }
        cancelPreparation()
        prepared = nil
        saved = false
        message = nil
    }
}
