import Foundation
import MihonCompatKit

public enum ReaderImagePipelineError: Error, LocalizedError, Sendable, Equatable {
    case httpStatus(Int)
    case emptyBody
    case imageTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(code):
            return "The page image server returned HTTP \(code)."
        case .emptyBody:
            return "The page image response was empty."
        case let .imageTooLarge(limit):
            return "The compressed page image exceeds the \(limit)-byte safety limit."
        }
    }
}

/// Controls whether one reader image load may reuse compressed bytes already
/// cached for the same public and source-scoped request identity.
public enum ReaderImageLoadPolicy: Sendable {
    case useCache
    case reload
}

public enum ReaderImageCachePolicy: Sendable {
    case memory
    case disabled
}

/// Source-scoped, bounded compressed-image loading for the reader. Production
/// requests reuse MihonCompatKit's streaming transport, redirect policy,
/// header validation, body limit, and isolated cookie jar. Interpreted sources
/// can attach an opaque source-scoped executor that preserves their configured
/// OkHttp client, tags, and cookies. The in-memory cache is an explicit LRU and
/// concurrent requests for the same public and hidden execution identity share
/// one task.
public actor ReaderImagePipeline {
    private struct RequestIdentity: Hashable, Sendable {
        struct Header: Hashable, Sendable {
            let name: String
            let value: String
        }
        let url: String
        let headers: [Header]
        let executionID: UUID?
        let scopeID: UUID?
    }

    private struct CacheEntry {
        let data: Data
        var lastAccess: UInt64
    }

    private struct InFlightRequest {
        let id: UUID
        let task: Task<Data, Error>
        let isReload: Bool
        // Each caller owns its registration until completion or cancellation.
        // A speculative flight may acquire (and later lose) visible callers.
        var waiters: [UUID: Bool]
    }

    private let transport: any CompatHTTPTransport
    private let transportPolicy: CompatHTTPTransportPolicy
    private let maximumImageBytes: Int
    private let maximumCacheBytes: Int
    private var cache: [RequestIdentity: CacheEntry] = [:]
    private var cachedBytes = 0
    private var accessCounter: UInt64 = 0
    private var inFlight: [RequestIdentity: InFlightRequest] = [:]
    private var memoryConstrained = false

    public init(
        sourceID: String,
        maximumImageBytes: Int = 32 * 1024 * 1024,
        maximumCacheBytes: Int = 64 * 1024 * 1024,
        cachePolicy: ReaderImageCachePolicy = .memory,
        transport: (any CompatHTTPTransport)? = nil,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) {
        let imageLimit = max(1, min(maximumImageBytes, 128 * 1024 * 1024))
        self.maximumImageBytes = imageLimit
        switch cachePolicy {
        case .memory:
            self.maximumCacheBytes = max(1, min(maximumCacheBytes, 256 * 1024 * 1024))
        case .disabled:
            self.maximumCacheBytes = 0
        }
        let imageTransportPolicy = CompatHTTPTransportPolicy(
            requestTimeoutSeconds: min(45, transportPolicy.requestTimeoutSeconds),
            maximumRedirects: transportPolicy.maximumRedirects,
            maximumRequestHeaderBytes: transportPolicy.maximumRequestHeaderBytes,
            maximumRequestBodyBytes: 1,
            maximumResponseHeaderBytes: transportPolicy.maximumResponseHeaderBytes,
            maximumResponseBodyBytes: imageLimit,
            allowsInsecureHTTP: transportPolicy.allowsInsecureHTTP,
            allowsHTTPSDowngrade: transportPolicy.allowsHTTPSDowngrade
        )
        self.transportPolicy = imageTransportPolicy
        self.transport = transport ?? URLSessionCompatHTTPTransport(
            sourceID: "reader:\(sourceID)",
            policy: imageTransportPolicy
        )
    }

    public func data(
        for imageRequest: ImageRequest,
        policy: ReaderImageLoadPolicy = .useCache
    ) async throws -> Data {
        try await load(imageRequest, policy: policy, speculative: false)
    }

    private func load(
        _ imageRequest: ImageRequest,
        policy: ReaderImageLoadPolicy,
        speculative: Bool
    ) async throws -> Data {
        try Task.checkCancellation()
        if speculative && memoryConstrained { throw CancellationError() }
        try imageRequest.checkAvailability()

        // Validate every public projection before cache or in-flight lookup.
        // This keeps a newly regenerated request subject to the same URL and
        // header policy even when an older request used the same cache key.
        let request = CompatHTTPRequest(
            url: imageRequest.url,
            method: "GET",
            headers: imageRequest.headers
                .sorted { lhs, rhs in
                    if lhs.key != rhs.key { return lhs.key < rhs.key }
                    return lhs.value < rhs.value
                }
                .map { CompatHTTPHeader(name: $0.key, value: $0.value) }
        )
        try transportPolicy.validate(request: request)
        try Task.checkCancellation()

        let key = Self.cacheKey(for: imageRequest)

        switch policy {
        case .useCache:
            if var entry = cache[key] {
                try Task.checkCancellation()
                try imageRequest.checkAvailability()
                accessCounter &+= 1
                entry.lastAccess = accessCounter
                cache[key] = entry
                return entry.data
            }
        case .reload:
            // A retry must not replay a successful but undecodable 200 body.
            // If an ordinary prefetch is using this exact identity, cancel it
            // before replacing the in-flight entry. An already active reload
            // remains the shared flight for concurrent reload callers.
            try Task.checkCancellation()
            if let existing = inFlight[key], !existing.isReload {
                existing.task.cancel()
                inFlight.removeValue(forKey: key)
            }
            if let previous = cache.removeValue(forKey: key) {
                cachedBytes -= previous.data.count
            }
        }

        let waiterID = UUID()
        if var existing = inFlight[key] {
            existing.waiters[waiterID] = !speculative
            inFlight[key] = existing
            return try await awaitFlight(existing, key: key, waiterID: waiterID, imageRequest: imageRequest)
        }

        try Task.checkCancellation()
        let transport = self.transport
        let maximumImageBytes = self.maximumImageBytes
        let requestID = UUID()
        let isReload: Bool
        switch policy {
        case .useCache: isReload = false
        case .reload: isReload = true
        }
        let task = Task<Data, Error> {
            try Task.checkCancellation()
            let response: CompatHTTPResponse
            if let sourceResponse = try await imageRequest.executeSourceRequest() {
                // executeSourceRequest tracks the opaque executor itself.
                response = sourceResponse
            } else {
                response = try await imageRequest.whileAvailable {
                    try await transport.execute(request)
                }
            }
            try Task.checkCancellation()
            try imageRequest.checkAvailability()
            guard (200...299).contains(response.statusCode) else {
                throw ReaderImagePipelineError.httpStatus(response.statusCode)
            }
            guard !response.body.isEmpty else {
                throw ReaderImagePipelineError.emptyBody
            }
            guard response.body.count <= maximumImageBytes else {
                throw ReaderImagePipelineError.imageTooLarge(limit: maximumImageBytes)
            }
            return Data(response.body)
        }
        let flight = InFlightRequest(id: requestID, task: task, isReload: isReload,
                                     waiters: [waiterID: !speculative])
        inFlight[key] = flight
        return try await awaitFlight(flight, key: key, waiterID: waiterID, imageRequest: imageRequest)
    }

    private func awaitFlight(
        _ flight: InFlightRequest, key: RequestIdentity, waiterID: UUID, imageRequest: ImageRequest
    ) async throws -> Data {
        defer { removeWaiter(waiterID, from: key, flightID: flight.id) }
        return try await withTaskCancellationHandler {
            do {
                let data = try await flight.task.value
                try imageRequest.checkAvailability()
                if inFlight[key]?.id == flight.id {
                    inFlight.removeValue(forKey: key)
                    // Any waiter can publish the shared result, including a
                    // canceled initiator when other callers still need it.
                    // Superseded flights and pressure cannot refill the cache.
                    insert(data, for: key)
                }
                try Task.checkCancellation()
                return data
            } catch {
                if inFlight[key]?.id == flight.id {
                    inFlight.removeValue(forKey: key)
                }
                throw error
            }
        } onCancel: {
            Task { await self.removeWaiter(waiterID, from: key, flightID: flight.id) }
        }
    }

    private func removeWaiter(_ waiterID: UUID, from key: RequestIdentity, flightID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.removeValue(forKey: waiterID)
        if flight.waiters.isEmpty || (memoryConstrained && !flight.waiters.values.contains(true)) {
            flight.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = flight
        }
    }

    /// Keep demanded requests alive, release reloadable compressed bytes and
    /// disable speculative work for this reader's remaining lifetime. A later
    /// chapter reset must not immediately recreate the memory that was freed.
    public func handleMemoryPressure() {
        memoryConstrained = true
        cache.removeAll(keepingCapacity: false)
        cachedBytes = 0
        for (key, flight) in inFlight where !flight.waiters.values.contains(true) {
            flight.task.cancel()
            inFlight.removeValue(forKey: key)
        }
    }

    public func prefetch(_ requests: [ImageRequest]) async {
        guard !memoryConstrained, !Task.isCancelled else { return }
        let bounded = Array(requests.prefix(ReaderSettings.maximumPrefetchPages))
        await withTaskGroup(of: Void.self) { group in
            for request in bounded {
                group.addTask {
                    _ = try? await self.load(request, policy: .useCache, speculative: true)
                }
            }
        }
    }

    public func clear() {
        guard !Task.isCancelled else { return }
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
        cachedBytes = 0
    }

    func cacheStatistics() -> (entries: Int, bytes: Int, inFlightWaiters: Int, visibleWaiters: Int) {
        (cache.count, cachedBytes, inFlight.values.reduce(0) { $0 + $1.waiters.count },
         inFlight.values.reduce(0) { $0 + $1.waiters.values.filter { $0 }.count })
    }

    private func insert(_ data: Data, for key: RequestIdentity) {
        guard !memoryConstrained, data.count <= maximumCacheBytes else { return }
        if let previous = cache.removeValue(forKey: key) {
            cachedBytes -= previous.data.count
        }
        while cachedBytes + data.count > maximumCacheBytes,
              let oldest = cache.min(by: {
                  if $0.value.lastAccess != $1.value.lastAccess {
                      return $0.value.lastAccess < $1.value.lastAccess
                  }
                  return $0.key.url < $1.key.url
              }) {
            cache.removeValue(forKey: oldest.key)
            cachedBytes -= oldest.value.data.count
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(data: data, lastAccess: accessCounter)
        cachedBytes += data.count
    }

    private static func cacheKey(for request: ImageRequest) -> RequestIdentity {
        let headers = request.headers.sorted(by: {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.value < $1.value
        }).map { RequestIdentity.Header(name: $0.key, value: $0.value) }
        // Hidden identities occupy distinct fields: an HTTP header named
        // source-execution or source-lifetime cannot impersonate either one.
        return RequestIdentity(url: request.url, headers: headers,
            executionID: request.sourceExecutionID, scopeID: request.requestScopeID)
    }
}
