import Foundation

public enum LibraryRefreshInterval: Int, Codable, CaseIterable, Sendable {
    case sixHours = 6, twelveHours = 12, daily = 24
    public var seconds: TimeInterval { TimeInterval(rawValue * 3_600) }
}

public enum LibraryRefreshOutcome: String, Codable, Sendable {
    case running, completed, partial, cancelled, failed, busy
}

public struct LibraryRefreshAttempt: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public internal(set) var outcome: LibraryRefreshOutcome
}

public struct LibraryRefreshSettings: Codable, Equatable, Sendable {
    var version = 1
    public internal(set) var enabled = false
    public internal(set) var interval = LibraryRefreshInterval.daily
    public internal(set) var nextEligibleAt: Date?
    public internal(set) var lastAttempt: LibraryRefreshAttempt?
}

public struct LibraryRefreshSettingsState: Equatable, Sendable {
    public let settings: LibraryRefreshSettings
    public let revision: UUID
    public let requiresRecovery: Bool
}

public enum LibraryRefreshSettingsError: Error, Equatable, LocalizedError {
    case invalidDocument, staleSettings, storageUnavailable, notDue
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "Automatic update settings could not be read. Review and save them again."
        case .staleSettings: "Automatic update settings changed. Reopen settings before saving."
        case .storageUnavailable: "Automatic update settings could not be confirmed. Automatic checks are stopped; review and save them again."
        case .notDue: "An automatic check is not due yet."
        }
    }
}

/// One small, app-wide durable schedule. No source identities, URLs or trust
/// live here. A successful write and readback are required before new work.
@MainActor
public final class LibraryRefreshSettingsStore {
    public nonisolated static let maximumBytes = 4_096
    public nonisolated static let initialDelay: TimeInterval = 15 * 60
    public private(set) var state: LibraryRefreshSettingsState {
        didSet { onChange?(state) }
    }
    public var onChange: ((LibraryRefreshSettingsState) -> Void)?
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private var observed: Data?
    private var hasRead = false

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read; self.write = write
        var settings = LibraryRefreshSettings()
        var recovery = false
        do {
            let data = try read()
            observed = data; hasRead = true
            settings = try data.map(Self.decode) ?? settings
        } catch { recovery = true }
        state = .init(settings: settings, revision: UUID(), requiresRecovery: recovery)
    }

    public convenience init(fileURL: URL) {
        self.init(read: {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: fileURL) }
            catch {
                if SourceDiscoveryStore.isMissingFile(error) { return nil }
                throw error
            }
            defer { try? handle.close() }
            var data = Data()
            while data.count <= Self.maximumBytes {
                let chunk = try handle.read(upToCount: Self.maximumBytes + 1 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return data
        }, write: { data in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        })
    }

    public func save(enabled: Bool, interval: LibraryRefreshInterval, expectedRevision: UUID, now: Date) throws {
        guard expectedRevision == state.revision else { throw LibraryRefreshSettingsError.staleSettings }
        try verifyObserved()
        try Self.validate(now)
        var value = state.requiresRecovery ? LibraryRefreshSettings() : state.settings
        if enabled {
            if !value.enabled {
                value.nextEligibleAt = now.addingTimeInterval(Self.initialDelay)
            } else if value.interval != interval {
                value.nextEligibleAt = value.lastAttempt?.startedAt.addingTimeInterval(interval.seconds)
                    ?? value.nextEligibleAt
            }
            value.nextEligibleAt = min(value.nextEligibleAt ?? now, now.addingTimeInterval(interval.seconds))
        } else { value.nextEligibleAt = nil }
        value.enabled = enabled; value.interval = interval
        try persist(value)
    }

    /// A backwards wall-clock change may delay work by at most one interval.
    /// Forward jumps make one attempt due, never a burst of catch-up requests.
    public func reconcile(now: Date) throws {
        try verifyObserved()
        guard !state.requiresRecovery else { throw LibraryRefreshSettingsError.invalidDocument }
        try Self.validate(now)
        if let next = state.settings.nextEligibleAt,
           next > now.addingTimeInterval(state.settings.interval.seconds) {
            var value = state.settings
            value.nextEligibleAt = now.addingTimeInterval(value.interval.seconds)
            try persist(value)
        }
    }

    func beginAttempt(now: Date) throws -> UUID {
        try reconcile(now: now)
        guard state.settings.enabled, let next = state.settings.nextEligibleAt, now >= next else {
            throw LibraryRefreshSettingsError.notDue
        }
        var value = state.settings
        let id = UUID()
        value.lastAttempt = .init(id: id, startedAt: now, outcome: .running)
        value.nextEligibleAt = now.addingTimeInterval(value.interval.seconds)
        try persist(value)
        return id
    }

    func finishAttempt(_ id: UUID, outcome: LibraryRefreshOutcome, now: Date) throws {
        try verifyObserved()
        guard !state.requiresRecovery, state.settings.lastAttempt?.id == id,
              outcome != .running else { throw LibraryRefreshSettingsError.staleSettings }
        try Self.validate(now)
        var value = state.settings
        value.lastAttempt?.outcome = outcome
        if value.enabled, outcome == .busy {
            value.nextEligibleAt = min(value.nextEligibleAt ?? now, now.addingTimeInterval(Self.initialDelay))
        }
        try persist(value)
    }

    private func verifyObserved() throws {
        let data: Data?
        do { data = try read() }
        catch {
            hasRead = false; close()
            throw LibraryRefreshSettingsError.storageUnavailable
        }
        guard hasRead, data == observed else {
            observed = data; hasRead = true; close()
            throw LibraryRefreshSettingsError.staleSettings
        }
    }

    private func persist(_ settings: LibraryRefreshSettings) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        _ = try Self.decode(data)
        if settings == state.settings, !state.requiresRecovery { return }
        do {
            try write(data)
            guard try read() == data else { throw LibraryRefreshSettingsError.storageUnavailable }
        } catch {
            do { observed = try read(); hasRead = true } catch { hasRead = false }
            close()
            throw LibraryRefreshSettingsError.storageUnavailable
        }
        observed = data; hasRead = true
        state = .init(settings: settings, revision: UUID(), requiresRecovery: false)
    }

    private func close() {
        state = .init(settings: LibraryRefreshSettings(), revision: UUID(), requiresRecovery: true)
    }

    private static func validate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite,
              (0...253_402_214_399).contains(date.timeIntervalSince1970) else {
            throw LibraryRefreshSettingsError.invalidDocument
        }
    }

    static func decode(_ data: Data) throws -> LibraryRefreshSettings {
        do {
            guard data.count <= maximumBytes else { throw LibraryRefreshSettingsError.invalidDocument }
            let policy = try LibraryBackupPolicy(maximumInputBytes: maximumBytes, maximumDepth: 3,
                maximumJSONValues: 24, maximumJSONStringBytes: 512, maximumJSONObjectKeys: 5,
                maximumJSONArrayElements: 1)
            var lexical = try LibraryBackupJSONPreflight(data: data, policy: policy)
            try lexical.run()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["version", "enabled", "interval", "nextEligibleAt", "lastAttempt"]) else {
                throw LibraryRefreshSettingsError.invalidDocument
            }
            if let attempt = object["lastAttempt"] as? [String: Any],
               Set(attempt.keys) != ["id", "startedAt", "outcome"] { throw LibraryRefreshSettingsError.invalidDocument }
            let value = try JSONDecoder().decode(LibraryRefreshSettings.self, from: data)
            guard value.version == 1, value.enabled == (value.nextEligibleAt != nil) else {
                throw LibraryRefreshSettingsError.invalidDocument
            }
            if let next = value.nextEligibleAt { try validate(next) }
            if let last = value.lastAttempt { try validate(last.startedAt) }
            return value
        } catch { throw LibraryRefreshSettingsError.invalidDocument }
    }
}
