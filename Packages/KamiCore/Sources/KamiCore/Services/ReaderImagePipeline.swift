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

/// Source-scoped, bounded compressed-image loading for the reader. Production
/// requests reuse MihonCompatKit's streaming transport, redirect policy,
/// header validation, body limit, and isolated cookie jar. The in-memory cache
/// is an explicit LRU and concurrent requests for the same URL/header identity
/// share one transport task.
public actor ReaderImagePipeline {
    private struct CacheEntry {
        let data: Data
        var lastAccess: UInt64
    }

    private struct InFlightRequest {
        let id: UUID
        let task: Task<Data, Error>
    }

    private let transport: any CompatHTTPTransport
    private let transportPolicy: CompatHTTPTransportPolicy
    private let maximumImageBytes: Int
    private let maximumCacheBytes: Int
    private var cache: [String: CacheEntry] = [:]
    private var cachedBytes = 0
    private var accessCounter: UInt64 = 0
    private var inFlight: [String: InFlightRequest] = [:]

    public init(
        sourceID: String,
        maximumImageBytes: Int = 32 * 1024 * 1024,
        maximumCacheBytes: Int = 64 * 1024 * 1024,
        transport: (any CompatHTTPTransport)? = nil,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) {
        let imageLimit = max(1, min(maximumImageBytes, 128 * 1024 * 1024))
        self.maximumImageBytes = imageLimit
        self.maximumCacheBytes = max(1, min(maximumCacheBytes, 256 * 1024 * 1024))
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

    public func data(for imageRequest: ImageRequest) async throws -> Data {
        let key = Self.cacheKey(for: imageRequest)
        if var entry = cache[key] {
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            cache[key] = entry
            return entry.data
        }
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

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
        let transport = self.transport
        let maximumImageBytes = self.maximumImageBytes
        let requestID = UUID()
        let task = Task<Data, Error> {
            let response = try await transport.execute(request)
            try Task.checkCancellation()
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
        inFlight[key] = InFlightRequest(id: requestID, task: task)

        do {
            let data = try await task.value
            if inFlight[key]?.id == requestID {
                inFlight.removeValue(forKey: key)
                insert(data, for: key)
            }
            return data
        } catch {
            if inFlight[key]?.id == requestID {
                inFlight.removeValue(forKey: key)
            }
            throw error
        }
    }

    public func prefetch(_ requests: [ImageRequest]) async {
        let bounded = Array(requests.prefix(ReaderSettings.maximumPrefetchPages))
        await withTaskGroup(of: Void.self) { group in
            for request in bounded {
                group.addTask {
                    _ = try? await self.data(for: request)
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

    func cacheStatistics() -> (entries: Int, bytes: Int) {
        (cache.count, cachedBytes)
    }

    private func insert(_ data: Data, for key: String) {
        guard data.count <= maximumCacheBytes else { return }
        if let previous = cache.removeValue(forKey: key) {
            cachedBytes -= previous.data.count
        }
        while cachedBytes + data.count > maximumCacheBytes,
              let oldest = cache.min(by: {
                  if $0.value.lastAccess != $1.value.lastAccess {
                      return $0.value.lastAccess < $1.value.lastAccess
                  }
                  return $0.key < $1.key
              }) {
            cache.removeValue(forKey: oldest.key)
            cachedBytes -= oldest.value.data.count
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(data: data, lastAccess: accessCounter)
        cachedBytes += data.count
    }

    private static func cacheKey(for request: ImageRequest) -> String {
        var key = request.url
        for header in request.headers.sorted(by: {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.value < $1.value
        }) {
            key += "\u{0}\(header.key)\u{0}\(header.value)"
        }
        return key
    }
}
