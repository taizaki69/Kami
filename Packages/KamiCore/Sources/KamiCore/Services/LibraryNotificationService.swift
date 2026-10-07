import Foundation

@MainActor
public protocol LibraryNotificationPlatform: AnyObject {
    func authorization() async -> LibraryNotificationAuthorization
    /// Called only from an explicit foreground user action, never by process().
    func requestAuthorization() async throws
    func contains(identifier: String) async -> Bool
    func submit(_ batch: LibraryNotificationBatch) async throws
    func remove(identifier: String) async
    func removeOwned() async
}

protocol LibraryNotificationPersisting: Sendable {
    func libraryNotificationSettings() async throws -> LibraryNotificationSettings
    func saveLibraryNotificationSettings(enabled: Bool, expectedRevision: Int64) async throws -> LibraryNotificationSettings
    func claimLibraryNotificationBatch(expectedRevision: Int64) async throws -> LibraryNotificationBatch?
    func finishLibraryNotificationBatch(id: UUID, outcome: LibraryNotificationOutcome) async throws
}

#if canImport(SQLite3)
extension LibraryStore: LibraryNotificationPersisting {}
#endif

/// Serial OS submission with durable, at-most-once batch attempts. The app
/// holds its library-operation lease through this method, including drainage.
@MainActor
public final class LibraryNotificationService {
    public private(set) var settings: LibraryNotificationSettings?
    public private(set) var authorization: LibraryNotificationAuthorization = .notDetermined
    public private(set) var error: String?
    public private(set) var isSaving = false
    public private(set) var isRequesting = false
    public var onChange: (@MainActor () -> Void)?
    private let persistence: any LibraryNotificationPersisting
    private let platform: any LibraryNotificationPlatform
    private let available: Bool
    private var processing = false
    private var generation: UInt64 = 0
    private var requiresReview = false

#if canImport(SQLite3)
    public convenience init(store: LibraryStore, platform: any LibraryNotificationPlatform, available: Bool = true) {
        self.init(persistence: store, platform: platform, available: available)
    }
#endif
    init(persistence: any LibraryNotificationPersisting, platform: any LibraryNotificationPlatform, available: Bool = true) {
        self.persistence = persistence; self.platform = platform; self.available = available
    }

    public func save(enabled: Bool, expectedRevision: Int64) async throws {
        guard available else { throw LibraryNotificationError.storageUnavailable }
        guard !isSaving else { throw LibraryNotificationError.busy }
        isSaving = true; generation &+= 1
        onChange?()
        defer { isSaving = false; onChange?() }
        do {
            settings = try await persistence.saveLibraryNotificationSettings(enabled: enabled, expectedRevision: expectedRevision)
            requiresReview = false; error = nil
            if !enabled { await platform.removeOwned() }
        } catch {
            requiresReview = true; settings = nil
            let failure = error as? LibraryNotificationError ?? .storageUnavailable
            self.error = failure.errorDescription
            throw failure
        }
    }

    /// Explicit Reload after a failed save. Until reviewed, processing is off
    /// in this process; a failed write does not promise persistence after relaunch.
    public func reloadSettings() async {
        guard available else { error = LibraryNotificationError.storageUnavailable.errorDescription; onChange?(); return }
        guard !isSaving else { return }
        let captured = generation
        do {
            let value = try await persistence.libraryNotificationSettings()
            guard captured == generation else { return }
            settings = value; requiresReview = false; error = nil
            authorization = await platform.authorization()
        } catch { self.error = LibraryNotificationError.storageUnavailable.errorDescription; requiresReview = true }
        onChange?()
    }

    public func requestPermission() async {
        guard available, settings?.enabled == true, !requiresReview, !isRequesting else { return }
        isRequesting = true; onChange?()
        defer { isRequesting = false; onChange?() }
        let captured = generation
        do {
            let current = await platform.authorization()
            guard captured == generation, settings?.enabled == true else { return }
            if current == .notDetermined { try await platform.requestAuthorization() }
            authorization = await platform.authorization()
            error = nil
        } catch { self.error = "Notification permission could not be requested. Try again while Kami is active." }
    }

    public func process() async {
        guard available else { error = LibraryNotificationError.storageUnavailable.errorDescription; onChange?(); return }
        guard !processing, !isSaving, !requiresReview, !Task.isCancelled else { return }
        processing = true
        let captured = generation
        defer { processing = false; onChange?() }
        do {
            let current = try await persistence.libraryNotificationSettings()
            guard captured == generation else { return }
            settings = current
            guard current.enabled else { await platform.removeOwned(); return }
            authorization = await platform.authorization()
            guard captured == generation, !Task.isCancelled else { return }
            if current.outcome == .attempting, let old = current.batch {
                let present = await platform.contains(identifier: old.identifier)
                // Absence cannot distinguish never submitted, already dismissed,
                // or delivered before a crash. Consume rather than alert twice.
                try await persistence.finishLibraryNotificationBatch(id: old.id, outcome: present ? .submitted : .unconfirmed)
                let recovered = try await persistence.libraryNotificationSettings()
                guard captured == generation else { return }
                settings = recovered
            }
            guard authorization == .allowed, captured == generation, !Task.isCancelled else { return }
            guard let batch = try await persistence.claimLibraryNotificationBatch(expectedRevision: current.revision) else { return }
            var outcome = LibraryNotificationOutcome.unconfirmed
            var cancelled = Task.isCancelled
            do {
                let latest = try await persistence.libraryNotificationSettings()
                guard latest.enabled, latest.revision == current.revision, captured == generation, !Task.isCancelled else {
                    throw CancellationError()
                }
                try await platform.submit(batch)
                outcome = .submitted
            } catch is CancellationError { cancelled = true }
            catch { self.error = "The last chapter alert could not be confirmed. Saved chapters are available in Updates." }
            cancelled = cancelled || Task.isCancelled
            // Cancellation must drain the platform call and persist its terminal
            // record. This cleanup task is owned and awaited, never fire-and-forget.
            let completion = Task { @MainActor in
                do {
                    let latest = try await self.persistence.libraryNotificationSettings()
                    if cancelled || captured != self.generation || !latest.enabled || latest.revision != current.revision {
                        await self.platform.remove(identifier: batch.identifier)
                        outcome = .unconfirmed
                    }
                    try await self.persistence.finishLibraryNotificationBatch(id: batch.id, outcome: outcome)
                    let updated = try await self.persistence.libraryNotificationSettings()
                    if captured == self.generation {
                        self.settings = updated
                        if updated.outcome == .submitted { self.error = nil }
                    }
                } catch {
                    await self.platform.remove(identifier: batch.identifier)
                    self.error = LibraryNotificationError.storageUnavailable.errorDescription
                    self.requiresReview = true
                }
            }
            await completion.value
        } catch is CancellationError {}
        catch LibraryNotificationError.settingsChanged {}
        catch {
            self.error = LibraryNotificationError.storageUnavailable.errorDescription
            requiresReview = true
        }
    }
}
