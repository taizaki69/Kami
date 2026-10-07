import SwiftUI
import BackgroundTasks
import KamiCore

@MainActor
final class IOSLibraryRefreshRequests {
    static let identifier = "app.kami.reader.library-refresh"
    private var registrationAttempted = false
    private var registered = false
    var isRegistered: Bool { registered }

    var isAvailable: Bool { registered && UIApplication.shared.backgroundRefreshStatus == .available }

    func register(operation: @escaping @MainActor @Sendable () async -> Bool) {
        guard !registrationAttempted else { return }
        registrationAttempted = true
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            guard task is BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let owner = LibraryRefreshTaskOwner { success in
                task.expirationHandler = nil
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = { owner.expire() }
            owner.start { await operation() }
        }
    }

    func submit(earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliest
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
}

@MainActor
struct AutomaticUpdatesSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var interval = LibraryRefreshInterval.daily
    @State private var revision: UUID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Check automatically", isOn: $enabled)
                    Picker("Minimum interval", selection: $interval) {
                        Text("6 hours").tag(LibraryRefreshInterval.sixHours)
                        Text("12 hours").tag(LibraryRefreshInterval.twelveHours)
                        Text("24 hours").tag(LibraryRefreshInterval.daily)
                    }.disabled(!enabled)
                } footer: {
                    Text("iOS chooses when to run checks and may delay or skip them. The first request allows at least 15 minutes. Checks use your saved library and ready sources, including sources hidden from Browse. They may use cellular data. Chapters are not downloaded automatically.")
                }
                Section("Status") {
                    status
                    if model.automaticUpdates.isRunning { ProgressView("Automatic check in progress…") }
                    if let attempt = model.automaticUpdates.settings.state.settings.lastAttempt {
                        LabeledContent("Last automatic attempt") { Text(attempt.startedAt, style: .relative) }
                        Text(outcomeLabel(attempt.outcome)).font(.footnote)
                    }
                    Text("Review saved chapters and per-manga outcomes in Updates. You can still check manually at any time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Reload settings") { reload() }
                    }
                }
            }
            .navigationTitle("Automatic updates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let revision else { return }
                        do {
                            try model.automaticUpdates.save(enabled: enabled, interval: interval, expectedRevision: revision)
                            self.revision = model.automaticUpdates.settings.state.revision
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }.disabled(revision == nil)
                }
            }
            .onAppear { model.automaticUpdates.reconcile(); reload() }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.automaticUpdates.status {
        case .disabled: Text("Automatic checks are off.")
        case let .scheduled(date):
            Text("Requested from iOS. Earliest eligible time:")
            Text(date, format: .dateTime.month().day().hour().minute())
        case .systemUnavailable:
            Text(model.automaticUpdatesUnavailableMessage)
        case .submissionFailed:
            Text("The request could not be scheduled. Your preference is saved.")
            Button("Retry scheduling") { model.automaticUpdates.reconcile() }
        case .storageUnavailable:
            Text("Saved settings could not be confirmed. Automatic checks are stopped. Review and save your choices again.")
        }
    }

    private func reload() {
        let state = model.automaticUpdates.settings.state
        enabled = state.settings.enabled; interval = state.settings.interval
        revision = state.revision; error = nil
    }

    private func outcomeLabel(_ value: LibraryRefreshOutcome) -> String {
        switch value {
        case .running: model.automaticUpdates.isRunning ? "Checking…" : "The previous attempt did not record completion. Saved chapters have been kept."
        case .completed: "The check finished. Some manga may have been skipped; review Updates."
        case .partial: "Some requests failed. Results already saved have been kept."
        case .cancelled: "The check stopped before finishing. Results already saved have been kept."
        case .failed: "The check could not finish. Review Updates for saved results."
        case .busy: "Another library operation was active. A later check has been requested."
        }
    }
}
