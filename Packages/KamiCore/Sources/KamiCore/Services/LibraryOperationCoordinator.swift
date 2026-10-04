import Foundation

/// Shared by all scenes of one app model. This is presentation identity, not
/// the durable database epoch and not a restore preview or source capability.
public struct LibraryPresentationGeneration: Hashable, Sendable {
    fileprivate let id: UUID
}

public struct LibraryOperationState: Equatable, Sendable {
    public let presentation: LibraryPresentationGeneration
    public let activeOperations: Int
    public let isExclusive: Bool
}

public struct LibraryExclusiveOperation: Sendable {
    fileprivate let owner: UUID
    fileprivate let id: UUID
}

public enum LibraryOperationError: Error, Equatable, Sendable, LocalizedError {
    case exclusiveInProgress
    case operationsInProgress
    case stalePresentation
    case invalidOperation
    case operationLimitReached

    public var errorDescription: String? {
        switch self {
        case .exclusiveInProgress:
            "The library is changing. Please wait until it finishes."
        case .operationsInProgress:
            "Close open readers and let pending library operations finish before continuing."
        case .stalePresentation:
            "The library changed. Reopen this screen before continuing."
        case .invalidOperation:
            "This library operation is no longer available. Reopen the screen and try again."
        case .operationLimitReached:
            "Too many library operations are pending. Let them finish and try again."
        }
    }
}

private struct LibraryOperationContext: Sendable {
    let owner: UUID
    let id: UUID
    let presentation: LibraryPresentationGeneration
}

private enum LibraryOperationScope {
    @TaskLocal static var current: LibraryOperationContext?
}

/// A lifetime reservation. Closing prevents new work, but cannot release
/// workers already registered with start/withScope until they actually drain.
@MainActor
public final class LibraryOperationLease {
    public nonisolated static let maximumWorkers = 128
    private let coordinator: LibraryOperationCoordinator
    fileprivate let context: LibraryOperationContext
    private var workers = 0
    private var closing = false

    fileprivate init(coordinator: LibraryOperationCoordinator, context: LibraryOperationContext) {
        self.coordinator = coordinator
        self.context = context
    }

    public var presentation: LibraryPresentationGeneration { context.presentation }

    /// Registers the worker synchronously, before its Task can be scheduled.
    /// Cancelling an observer of value does not cancel this owned worker.
    public func start<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) throws -> Task<Value, Error> {
        try reserveWorker()
        return Task { @MainActor in try await self.execute(operation) }
    }

    /// For lifecycle work whose reservation already exists before suspension.
    public func withScope<Value: Sendable>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try reserveWorker()
        return try await execute(operation)
    }

    public func close() {
        closing = true
        if workers == 0 { coordinator.release(context) }
    }

    private func reserveWorker() throws {
        guard !closing else { throw LibraryOperationError.invalidOperation }
        try coordinator.validate(context)
        guard workers < Self.maximumWorkers else { throw LibraryOperationError.operationLimitReached }
        workers += 1
    }

    private func execute<Value: Sendable>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        defer {
            workers -= 1
            if closing, workers == 0 { coordinator.release(context) }
        }
        try Task.checkCancellation()
        return try await LibraryOperationScope.$current.withValue(context) {
            try await operation()
        }
    }
}

/// One coordinator belongs to one AppModel, outside WindowGroup. Store
/// transactions still validate their captured durable epoch and exact IDs.
@MainActor
public final class LibraryOperationCoordinator {
    public nonisolated static let maximumOperations = 256
    private let owner = UUID()
    private let limit: Int
    private var presentation = LibraryPresentationGeneration(id: UUID())
    private var active = Set<UUID>()
    private var exclusive: UUID?
    private var committedPresentationPublished = false

    public var onStateChanged: ((LibraryOperationState) -> Void)? {
        didSet { onStateChanged?(state) }
    }

    public var state: LibraryOperationState {
        .init(presentation: presentation, activeOperations: active.count, isExclusive: exclusive != nil)
    }

    public init(maximumOperations: Int = LibraryOperationCoordinator.maximumOperations) {
        precondition((1...Self.maximumOperations).contains(maximumOperations))
        limit = maximumOperations
    }

    public func open(expected: LibraryPresentationGeneration) throws -> LibraryOperationLease {
        guard expected == presentation else { throw LibraryOperationError.stalePresentation }
        guard exclusive == nil else { throw LibraryOperationError.exclusiveInProgress }
        guard active.count < limit else { throw LibraryOperationError.operationLimitReached }
        let id = UUID()
        active.insert(id)
        let lease = LibraryOperationLease(coordinator: self,
            context: .init(owner: owner, id: id, presentation: presentation))
        onStateChanged?(state)
        return lease
    }

    public func start<Value: Sendable>(
        expected: LibraryPresentationGeneration,
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) throws -> Task<Value, Error> {
        let lease = try open(expected: expected)
        defer { lease.close() }
        return try lease.start(operation)
    }

    /// Inherited TaskLocal scope is validation, not ownership. An independent
    /// worker must call start before its parent's reservation can close.
    public func validateCurrentOperation() throws {
        guard let context = LibraryOperationScope.current else { throw LibraryOperationError.invalidOperation }
        try validate(context)
    }

    public func beginExclusive(expected: LibraryPresentationGeneration) throws -> LibraryExclusiveOperation {
        guard expected == presentation else { throw LibraryOperationError.stalePresentation }
        guard exclusive == nil else { throw LibraryOperationError.exclusiveInProgress }
        guard active.isEmpty else { throw LibraryOperationError.operationsInProgress }
        let id = UUID()
        exclusive = id
        committedPresentationPublished = false
        onStateChanged?(state)
        return .init(owner: owner, id: id)
    }

    /// Call only after a successful database commit. Keep exclusion while the
    /// app clears old presentation and publishes the new stored snapshot.
    public func publishCommittedChange(_ operation: LibraryExclusiveOperation) throws {
        try validateExclusive(operation)
        guard !committedPresentationPublished else { throw LibraryOperationError.invalidOperation }
        committedPresentationPublished = true
        presentation = .init(id: UUID())
        onStateChanged?(state)
    }

    /// Abort before publication preserves generation; completion after
    /// publication preserves the committed generation, including cancellation.
    public func finishExclusive(_ operation: LibraryExclusiveOperation) throws {
        try validateExclusive(operation)
        exclusive = nil
        onStateChanged?(state)
    }

    fileprivate func validate(_ context: LibraryOperationContext) throws {
        guard context.owner == owner, active.contains(context.id) else {
            throw LibraryOperationError.invalidOperation
        }
        guard context.presentation == presentation else { throw LibraryOperationError.stalePresentation }
    }

    fileprivate func release(_ context: LibraryOperationContext) {
        guard context.owner == owner, active.remove(context.id) != nil else { return }
        onStateChanged?(state)
    }

    private func validateExclusive(_ operation: LibraryExclusiveOperation) throws {
        guard operation.owner == owner, exclusive == operation.id else { throw LibraryOperationError.invalidOperation }
    }
}
