import Foundation
import MihonCompatKit

public struct SourceDiscoveryState: Equatable, Sendable {
    public let preferences: SourceDiscoveryPreferences
    public let revision: UUID
    public let requiresRecovery: Bool
}

/// A revocable selection lifetime, independent of source admission/lifetime.
public struct SourceDiscoverySelectionSnapshot: Sendable {
    public let preferences: SourceDiscoveryPreferences
    private let scope: SourceRequestScope
    public var id: UUID { scope.id }
    public var isCurrent: Bool { scope.isActive }

    fileprivate init(preferences: SourceDiscoveryPreferences, scope: SourceRequestScope) {
        self.preferences = preferences
        self.scope = scope
    }

    // Register cancellation before dispatching. Revoking a selection reaches
    // active providers even if no SwiftUI observer is currently rendering.
    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await scope.perform(operation)
    }
}

/// One app-wide owner shared by scenes. Saves compare the editor revision and
/// last observed bytes; failures never silently expand the search audience.
@MainActor
public final class SourceDiscoveryStore {
    public private(set) var state: SourceDiscoveryState {
        didSet { onChange?(state) }
    }
    public var onChange: ((SourceDiscoveryState) -> Void)? {
        didSet { onChange?(state) }
    }
    private let read: @MainActor () throws -> Data?
    private let write: @MainActor (Data) throws -> Void
    private var lastData: Data?
    private var hasRead = false
    private var scope = SourceRequestScope()

    public init(read: @escaping @MainActor () throws -> Data?,
                write: @escaping @MainActor (Data) throws -> Void) {
        self.read = read
        self.write = write
        var preferences = SourceDiscoveryPreferences.none
        var recovery = false
        do {
            let data = try read()
            lastData = data
            hasRead = true
            preferences = try data.map(SourceDiscoveryPreferences.decode) ?? .all
        } catch { recovery = true }
        state = .init(preferences: preferences, revision: scope.id, requiresRecovery: recovery)
    }

    public convenience init(fileURL: URL) {
        self.init(read: {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: fileURL) }
            catch {
                guard Self.isMissingFile(error) else { throw error }
                return nil
            }
            defer { try? handle.close() }
            var data = Data()
            let limit = SourceDiscoveryPreferences.maximumBytes + 1
            while data.count < limit {
                let chunk = try handle.read(upToCount: limit - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return data
        }, write: { data in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        })
    }

    public func snapshot() -> SourceDiscoverySelectionSnapshot {
        .init(preferences: state.preferences, scope: scope)
    }

    // Foundation's file-handle open reports absence through Cocoa on some
    // platforms and POSIX on others. Only these explicit absence codes mean
    // a fresh selection; permission/corruption/unknown errors stay closed.
    nonisolated static func isMissingFile(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            return value.code == CocoaError.fileNoSuchFile.rawValue
                || value.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        return value.domain == NSPOSIXErrorDomain && value.code == Int(POSIXErrorCode.ENOENT.rawValue)
    }

    public func save(_ preferences: SourceDiscoveryPreferences, expectedRevision: UUID) throws {
        guard expectedRevision == state.revision else { throw SourceDiscoveryPreferencesError.staleSelection }
        let observed: Data?
        do { observed = try read() }
        catch {
            hasRead = false
            publish(.none, requiresRecovery: true)
            throw SourceDiscoveryPreferencesError.persistenceUnavailable
        }
        guard hasRead, observed == lastData else {
            lastData = observed
            hasRead = true
            publish(.none, requiresRecovery: true)
            throw SourceDiscoveryPreferencesError.staleSelection
        }
        if preferences == state.preferences, !state.requiresRecovery { return }
        let data = try preferences.encoded()
        do {
            try write(data)
            guard try read() == data else { throw SourceDiscoveryPreferencesError.persistenceUnavailable }
        } catch {
            do { lastData = try read(); hasRead = true }
            catch { hasRead = false }
            publish(.none, requiresRecovery: true)
            throw SourceDiscoveryPreferencesError.persistenceUnavailable
        }
        lastData = data
        hasRead = true
        publish(preferences, requiresRecovery: false)
    }

    private func publish(_ preferences: SourceDiscoveryPreferences, requiresRecovery: Bool) {
        scope.revoke()
        scope = SourceRequestScope()
        state = .init(preferences: preferences, revision: scope.id, requiresRecovery: requiresRecovery)
    }
}
