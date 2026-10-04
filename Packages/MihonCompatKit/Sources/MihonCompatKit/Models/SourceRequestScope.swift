import Foundation

/// A revocable lifetime for one registered source instance. It grants no APK
/// trust or transport permission; it only cancels and rejects obsolete work.
public final class SourceRequestScope: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case tooManyOperations
        case differentLifetime

        public var errorDescription: String? {
            switch self {
            case .tooManyOperations:
                return "The source has too many active requests. Please try again."
            case .differentLifetime:
                return "This image request already belongs to another source registration."
            }
        }
    }

    public let id = UUID()
    private let lock = NSLock()
    private let maximumOperations: Int
    private var revoked = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    public init(maximumOperations: Int = 256) {
        self.maximumOperations = max(1, min(maximumOperations, 256))
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !revoked
    }

    public func checkAvailability() throws {
        guard isActive else { throw CancellationError() }
    }

    /// Revocation is permanent. Cancellation handlers run outside the lock.
    public func revoke() {
        lock.lock()
        revoked = true
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        for cancel in pending { cancel() }
    }

    public func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let (identifier, task) = try start(operation)
        defer { finish(identifier) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            try checkAvailability()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    private func start<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> (UUID, Task<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { throw CancellationError() }
        guard cancellations.count < maximumOperations else {
            throw Failure.tooManyOperations
        }
        let identifier = UUID()
        let task = Task {
            // This check takes the same lock: no operation starts before its
            // cancellation has been registered, even when revocation races it.
            try self.checkAvailability()
            try Task.checkCancellation()
            return try await operation()
        }
        cancellations[identifier] = { task.cancel() }
        return (identifier, task)
    }

    private func finish(_ identifier: UUID) {
        lock.lock()
        cancellations.removeValue(forKey: identifier)
        lock.unlock()
    }
}
