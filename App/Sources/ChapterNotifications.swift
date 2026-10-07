import SwiftUI
import UserNotifications
import KamiCore

@MainActor
final class IOSChapterNotifications: LibraryNotificationPlatform {
    private let center = UNUserNotificationCenter.current()
    func authorization() async -> LibraryNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }
    func requestAuthorization() async throws {
        guard UIApplication.shared.applicationState == .active else { throw LibraryNotificationError.busy }
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }
    func contains(identifier: String) async -> Bool {
        if await center.pendingNotificationRequests().contains(where: { $0.identifier == identifier }) { return true }
        return await center.deliveredNotifications().contains { $0.request.identifier == identifier }
    }
    func submit(_ batch: LibraryNotificationBatch) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Kami updates"
        content.body = batch.body
        content.sound = .default
        content.threadIdentifier = "app.kami.reader.chapters"
        try await center.add(UNNotificationRequest(identifier: batch.identifier, content: content, trigger: nil))
    }
    func remove(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    func removeOwned() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter(LibraryNotificationBatch.owns)
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter(LibraryNotificationBatch.owns)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}

final class ChapterNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let openUpdates: @MainActor @Sendable (String) -> Void
    init(openUpdates: @escaping @MainActor @Sendable (String) -> Void) { self.openUpdates = openUpdates }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        guard LibraryNotificationBatch.owns(identifier) else { return }
        await openUpdates(identifier)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Foreground reading stays quiet; the digest is still available in the
        // system's notification list. No badge or remote push registration.
        LibraryNotificationBatch.owns(notification.request.identifier) ? [.list] : []
    }
}

@MainActor
struct ChapterNotificationsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = false
    @State private var revision: Int64?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Notify about new chapters", isOn: $enabled)
                } footer: {
                    Text("Receive a summary after manual or automatic checks save new chapters. The first chapter list for each manga does not send an alert. Notifications show a count, without manga titles, and open Updates. iOS controls delivery, sounds and previews.")
                }
                Section("Permission and status") {
                    if model.chapterNotifications.settings?.enabled != true { Text("Chapter notifications are off.") }
                    switch model.chapterNotifications.authorization {
                    case .notDetermined:
                        Text("iOS permission has not been requested.")
                        if model.chapterNotifications.settings?.enabled == true {
                            Button("Allow notifications") { requestPermission() }
                        }
                    case .denied:
                        Text("Notifications are blocked in iOS Settings. Your saved choice will apply when permission is restored.")
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    case .allowed: Text("iOS permission is available.")
                    }
                    if let outcome = model.chapterNotifications.settings?.outcome {
                        switch outcome {
                        case .attempting: Text("The previous alert is being checked.")
                        case .submitted: Text("The last alert was accepted by iOS. Delivery may be delayed or silenced by your settings.")
                        case .unconfirmed: Text("The last alert could not be confirmed. Saved chapters are available in Updates.")
                        }
                    }
                    Text("Turning this off removes Kami's chapter alerts from the notification list. An alert that has already appeared or sounded cannot be recalled.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = error ?? model.chapterNotifications.error {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("If saving failed, the previous saved choice still applies after reopening Kami.").font(.footnote)
                        Button("Reload settings") { reload() }
                    }
                }
            }
            .navigationTitle("Chapter notifications")
            .disabled(working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let revision else { return }
                        let choice = enabled
                        working = true
                        let task = model.performLibraryOperation {
                            defer { working = false }
                            do {
                                try await model.chapterNotifications.save(enabled: choice, expectedRevision: revision)
                                self.revision = model.chapterNotifications.settings?.revision
                                error = nil
                                if choice { await model.chapterNotifications.requestPermission() }
                            } catch { self.error = error.localizedDescription }
                        }
                        if task == nil { working = false }
                    }.disabled(working || revision == nil || scenePhase != .active)
                }
            }
            .onAppear { reload() }
        }
    }
    private func reload() {
        working = true
        let task = model.performLibraryOperation {
            await model.chapterNotifications.reloadSettings()
            enabled = model.chapterNotifications.settings?.enabled ?? false
            revision = model.chapterNotifications.settings?.revision
            error = nil; working = false
        }
        if task == nil { working = false }
    }
    private func requestPermission() {
        model.performLibraryOperation { await model.chapterNotifications.requestPermission() }
    }
}
