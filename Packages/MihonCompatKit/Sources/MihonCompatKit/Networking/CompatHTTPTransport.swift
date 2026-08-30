import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CompatHTTPResponse: Sendable, Equatable {
    public let finalURL: String
    public let statusCode: Int
    public let headers: [CompatHTTPHeader]
    public let body: [UInt8]

    public init(finalURL: String, statusCode: Int,
                headers: [CompatHTTPHeader] = [], body: [UInt8] = []) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Hard limits and redirect rules for one extension source's HTTP boundary.
public struct CompatHTTPTransportPolicy: Sendable, Equatable {
    public let requestTimeoutSeconds: TimeInterval
    public let maximumRedirects: Int
    public let maximumRequestHeaderBytes: Int
    public let maximumRequestBodyBytes: Int
    public let maximumResponseHeaderBytes: Int
    public let maximumResponseBodyBytes: Int
    public let allowsInsecureHTTP: Bool
    public let allowsHTTPSDowngrade: Bool

    public init(
        requestTimeoutSeconds: TimeInterval = 30,
        maximumRedirects: Int = 5,
        maximumRequestHeaderBytes: Int = 64 * 1024,
        maximumRequestBodyBytes: Int = 2 * 1024 * 1024,
        maximumResponseHeaderBytes: Int = 64 * 1024,
        maximumResponseBodyBytes: Int = 16 * 1024 * 1024,
        allowsInsecureHTTP: Bool = true,
        allowsHTTPSDowngrade: Bool = false
    ) {
        self.requestTimeoutSeconds = max(1, min(requestTimeoutSeconds, 300))
        self.maximumRedirects = max(0, min(maximumRedirects, 20))
        self.maximumRequestHeaderBytes = max(1, min(maximumRequestHeaderBytes, 1024 * 1024))
        self.maximumRequestBodyBytes = max(1, min(maximumRequestBodyBytes, 128 * 1024 * 1024))
        self.maximumResponseHeaderBytes = max(1, min(maximumResponseHeaderBytes, 1024 * 1024))
        self.maximumResponseBodyBytes = max(1, min(maximumResponseBodyBytes, 128 * 1024 * 1024))
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.allowsHTTPSDowngrade = allowsHTTPSDowngrade
    }

    /// Validates a transport-neutral request against this source policy
    /// without performing network I/O. Reader and other app-facing seams use
    /// this before calling an injected transport, so a test transport cannot
    /// accidentally bypass URL, header, or scheme checks.
    public func validate(request: CompatHTTPRequest) throws {
        var headerNames = Set<String>()
        for header in request.headers {
            guard headerNames.insert(header.name.lowercased()).inserted else {
                throw CompatHTTPTransportError.invalidHeader
            }
        }
        _ = try CompatHTTPRequestEncoder.encode(request, policy: self)
    }
}

/// Async injection seam used by interpreted sources. A transport instance is
/// owned by exactly one source identity so cookies and future rate-limit state
/// never leak between extensions.
public protocol CompatHTTPTransport: Sendable {
    var sourceID: String { get }
    func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse
}

/// Optional transport capability for callers that need to observe one HTTP
/// exchange before redirect follow-up. The ordinary `execute` contract keeps
/// its existing automatic-redirect behavior; this narrower seam is used by
/// source-scoped reader requests whose network interceptors must see and may
/// rewrite a 3xx response before the next request is selected.
public protocol CompatHTTPSingleExchangeTransport: CompatHTTPTransport {
    func executeSingleExchange(
        _ request: CompatHTTPRequest
    ) async throws -> CompatHTTPResponse
}

/// Errors deliberately omit URLs, query strings, headers, cookies, and bodies.
public enum CompatHTTPTransportError: Swift.Error, Sendable, Equatable, CustomStringConvertible {
    case invalidURL
    case disallowedScheme
    case invalidMethod
    case invalidHeader
    case invalidCachePolicy
    case requestHeadersTooLarge(limit: Int)
    case requestBodyTooLarge(limit: Int)
    case responseHeadersTooLarge(limit: Int)
    case responseBodyTooLarge(limit: Int)
    case tooManyRedirects(limit: Int)
    case insecureRedirect
    case invalidResponse
    case cancelled
    case timedOut
    case network(code: Int)

    public var description: String {
        switch self {
        case .invalidURL: return "invalid HTTP URL"
        case .disallowedScheme: return "HTTP URL scheme is disallowed by policy"
        case .invalidMethod: return "invalid HTTP method"
        case .invalidHeader: return "invalid HTTP header"
        case .invalidCachePolicy: return "invalid HTTP cache policy"
        case let .requestHeadersTooLarge(limit): return "request headers exceed \(limit) bytes"
        case let .requestBodyTooLarge(limit): return "request body exceeds \(limit) bytes"
        case let .responseHeadersTooLarge(limit): return "response headers exceed \(limit) bytes"
        case let .responseBodyTooLarge(limit): return "response body exceeds \(limit) bytes"
        case let .tooManyRedirects(limit): return "redirect count exceeds \(limit)"
        case .insecureRedirect: return "HTTPS to HTTP redirect is disallowed"
        case .invalidResponse: return "HTTP response is missing or malformed"
        case .cancelled: return "HTTP request was cancelled"
        case .timedOut: return "HTTP request timed out"
        case let .network(code): return "HTTP transport failed with URL error code \(code)"
        }
    }
}

/// Production URLSession adapter. Response data is accumulated through
/// URLSessionDataDelegate callbacks, so the body limit is enforced while bytes
/// arrive rather than after URLSession has buffered the entire response.
public actor URLSessionCompatHTTPTransport: CompatHTTPSingleExchangeTransport {
    public nonisolated let sourceID: String
    public let policy: CompatHTTPTransportPolicy

    private var cookieJar = CompatHTTPCookieJar()
    private let protocolClasses: [AnyClass]?

    public init(sourceID: String, policy: CompatHTTPTransportPolicy = .init()) {
        self.sourceID = sourceID
        self.policy = policy
        self.protocolClasses = nil
    }

    init(sourceID: String, policy: CompatHTTPTransportPolicy = .init(),
         protocolClasses: [AnyClass]) {
        self.sourceID = sourceID
        self.policy = policy
        self.protocolClasses = protocolClasses
    }

    public func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
        try await execute(request, followsRedirects: true)
    }

    public func executeSingleExchange(
        _ request: CompatHTTPRequest
    ) async throws -> CompatHTTPResponse {
        try await execute(request, followsRedirects: false)
    }

    private func execute(
        _ request: CompatHTTPRequest,
        followsRedirects: Bool
    ) async throws -> CompatHTTPResponse {
        var encoded = try CompatHTTPRequestEncoder.encode(request, policy: policy)
        cookieJar.apply(to: &encoded)
        let response = try await CompatHTTPTaskRunner(
            policy: policy,
            protocolClasses: protocolClasses,
            followsRedirects: followsRedirects
        ).run(encoded)
        cookieJar.store(from: response)
        return response
    }

    public func clearCookies() {
        cookieJar.clear()
    }
}

struct CompatHTTPCookieJar {
    private struct StoredCookie {
        let cookie: HTTPCookie
        let hostOnly: Bool
    }

    private static let maximumCookies = 256
    private var cookies: [String: StoredCookie] = [:]

    mutating func apply(to request: inout URLRequest) {
        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              let url = request.url else { return }
        removeExpiredCookies()
        let matching = cookies.values.filter {
            Self.cookie($0, appliesTo: url)
        }.map(\.cookie).sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.name < $1.name
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    mutating func store(from response: CompatHTTPResponse) {
        guard let url = URL(string: response.finalURL) else { return }
        for header in response.headers where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            let hostOnly = !header.value.split(separator: ";").dropFirst().contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().hasPrefix("domain=")
            }
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": header.value],
                for: url
            )
            for cookie in parsed {
                let size = cookie.name.utf8.count + cookie.value.utf8.count
                    + cookie.domain.utf8.count + cookie.path.utf8.count
                guard size <= 8_192 else { continue }
                cookies[Self.cookieKey(cookie)] = StoredCookie(
                    cookie: cookie,
                    hostOnly: hostOnly
                )
            }
        }
        removeExpiredCookies()
        if cookies.count > Self.maximumCookies {
            for key in cookies.keys.sorted().prefix(cookies.count - Self.maximumCookies) {
                cookies.removeValue(forKey: key)
            }
        }
    }

    mutating func clear() {
        cookies.removeAll(keepingCapacity: false)
    }

    private mutating func removeExpiredCookies() {
        let now = Date()
        cookies = cookies.filter { _, stored in
            guard let expires = stored.cookie.expiresDate else { return true }
            return expires > now
        }
    }

    private static func cookieKey(_ cookie: HTTPCookie) -> String {
        cookie.name + "\u{0}" + cookie.domain.lowercased() + "\u{0}" + cookie.path
    }

    private static func cookie(_ stored: StoredCookie, appliesTo url: URL) -> Bool {
        let cookie = stored.cookie
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == domain || (!stored.hostOnly && host.hasSuffix("." + domain))
        guard domainMatches else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if requestPath.count == cookiePath.count || cookiePath.hasSuffix("/") { return true }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return requestPath[boundary] == "/"
    }
}

enum CompatHTTPRequestEncoder {
    static func encode(
        _ value: CompatHTTPRequest,
        policy: CompatHTTPTransportPolicy
    ) throws -> URLRequest {
        let url = try validatedURL(value.url, policy: policy)
        guard isHTTPToken(value.method), value.method.utf8.count <= 32 else {
            throw CompatHTTPTransportError.invalidMethod
        }

        var request = URLRequest(url: url)
        request.httpMethod = value.method
        request.timeoutInterval = policy.requestTimeoutSeconds
        var headerBytes = 0
        guard value.headers.count <= 256 else {
            throw CompatHTTPTransportError.requestHeadersTooLarge(
                limit: policy.maximumRequestHeaderBytes
            )
        }
        for header in value.headers {
            guard validHeader(name: header.name, value: header.value) else {
                throw CompatHTTPTransportError.invalidHeader
            }
            headerBytes += header.name.utf8.count + header.value.utf8.count + 4
            guard headerBytes <= policy.maximumRequestHeaderBytes else {
                throw CompatHTTPTransportError.requestHeadersTooLarge(
                    limit: policy.maximumRequestHeaderBytes
                )
            }
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }

        let encodedBody: Data?
        let defaultContentType: String?
        switch value.body {
        case nil:
            encodedBody = nil
            defaultContentType = nil
        case let .form(fields):
            guard fields.count <= 4_096 else {
                throw CompatHTTPTransportError.requestBodyTooLarge(
                    limit: policy.maximumRequestBodyBytes
                )
            }
            let body = fields.map {
                percentEncode($0.name) + "=" + percentEncode($0.value)
            }.joined(separator: "&")
            encodedBody = body.data(using: .utf8)
            defaultContentType = "application/x-www-form-urlencoded"
        case let .text(text, mediaType):
            if let mediaType, !validMediaType(mediaType) {
                throw CompatHTTPTransportError.invalidHeader
            }
            encodedBody = text.data(using: .utf8)
            defaultContentType = mediaType
        }
        if let encodedBody {
            guard encodedBody.count <= policy.maximumRequestBodyBytes else {
                throw CompatHTTPTransportError.requestBodyTooLarge(
                    limit: policy.maximumRequestBodyBytes
                )
            }
            request.httpBody = encodedBody
        }

        if let defaultContentType,
           request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(defaultContentType, forHTTPHeaderField: "Content-Type")
        }
        if let maxAge = value.cachePolicy?.maxAgeSeconds {
            guard maxAge >= 0 else { throw CompatHTTPTransportError.invalidCachePolicy }
            if request.value(forHTTPHeaderField: "Cache-Control") == nil {
                request.setValue("max-age=\(maxAge)", forHTTPHeaderField: "Cache-Control")
            }
        }
        let finalHeaderBytes = (request.allHTTPHeaderFields ?? [:]).reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count + 4
        }
        guard finalHeaderBytes <= policy.maximumRequestHeaderBytes else {
            throw CompatHTTPTransportError.requestHeadersTooLarge(
                limit: policy.maximumRequestHeaderBytes
            )
        }
        return request
    }

    static func validatedURL(
        _ text: String,
        policy: CompatHTTPTransportPolicy
    ) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 8_192,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              let components = URLComponents(string: text),
              components.user == nil, components.password == nil,
              let rawScheme = components.scheme,
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw CompatHTTPTransportError.invalidURL
        }
        let scheme = rawScheme.lowercased()
        guard scheme == "https" || (scheme == "http" && policy.allowsInsecureHTTP) else {
            throw CompatHTTPTransportError.disallowedScheme
        }
        return url
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let punctuation = Set("!#$%&'*+-.^_`|~".unicodeScalars.map(\.value))
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x41 && $0.value <= 0x5a)
                || ($0.value >= 0x61 && $0.value <= 0x7a)
                || punctuation.contains($0.value)
        }
    }

    private static func validHeader(name: String, value: String) -> Bool {
        isHTTPToken(name) && name.utf8.count <= 8_192
            && value.utf8.count <= 65_536
            && !value.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value == 0x0a || $0.value == 0x0d
            })
    }

    private static func validMediaType(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        let essence = value.split(separator: ";", maxSplits: 1).first ?? ""
        let parts = essence.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    private static func percentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            let unreserved = (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x30 && byte <= 0x39)
                || [0x2d, 0x2e, 0x5f, 0x7e].contains(byte)
            if unreserved {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0f)]))
            }
        }
        return result
    }
}

enum CompatHTTPHeaderPolicy {
    /// Request headers that must not cross an origin boundary. Keep this list
    /// shared with redirects and source-derived reader image requests.
    static let sensitiveHeaderNames = [
        "Authorization",
        "Proxy-Authorization",
        "Cookie",
        "Cookie2",
        "Host",
    ]

    private static let sensitiveHeaderNameSet = Set(
        sensitiveHeaderNames.map { $0.lowercased() }
    )

    static func isSensitiveHeader(_ name: String) -> Bool {
        sensitiveHeaderNameSet.contains(name.lowercased())
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// Source-derived page headers may cross to a CDN, but credentials must
    /// remain bound to the source origin. Invalid URLs are rejected by the
    /// caller's ordinary request policy after this filtering step.
    static func sourceImageHeaders(
        _ headers: [String: String],
        sourceBaseURL: String,
        imageURL: String
    ) -> [String: String]? {
        guard let sourceURL = URL(string: sourceBaseURL),
              let destinationURL = URL(string: imageURL) else { return nil }
        guard sameOrigin(sourceURL, destinationURL) else {
            return headers.filter { !isSensitiveHeader($0.key) }
        }
        return headers
    }
}

enum CompatHTTPRedirectPolicy {
    private static let redirectStatusCodes: Set<Int> = [300, 301, 302, 303, 307, 308]

    static func followUpGETRequest(
        from request: CompatHTTPRequest,
        response: CompatHTTPResponse,
        redirectCount: Int,
        policy: CompatHTTPTransportPolicy
    ) throws -> CompatHTTPRequest? {
        guard redirectStatusCodes.contains(response.statusCode),
              let location = response.headers.reversed().first(where: {
                  $0.name.caseInsensitiveCompare("Location") == .orderedSame
              })?.value else {
            return nil
        }
        guard request.method == "GET", request.body == nil,
              let sourceURL = URL(string: response.finalURL),
              let destination = URL(string: location, relativeTo: sourceURL)?.absoluteURL else {
            throw CompatHTTPTransportError.invalidResponse
        }
        guard redirectCount <= policy.maximumRedirects else {
            throw CompatHTTPTransportError.tooManyRedirects(limit: policy.maximumRedirects)
        }
        let validated = try CompatHTTPRequestEncoder.validatedURL(
            destination.absoluteString,
            policy: policy
        )
        if sourceURL.scheme?.lowercased() == "https",
           validated.scheme?.lowercased() == "http",
           !policy.allowsHTTPSDowngrade {
            throw CompatHTTPTransportError.insecureRedirect
        }

        let headers = CompatHTTPHeaderPolicy.sameOrigin(sourceURL, validated)
            ? request.headers
            : request.headers.filter {
            !CompatHTTPHeaderPolicy.isSensitiveHeader($0.name)
        }
        return CompatHTTPRequest(
            url: validated.absoluteString,
            method: "GET",
            headers: headers,
            cachePolicy: request.cachePolicy
        )
    }

    static func sanitizedRequest(
        from sourceURL: URL,
        proposed: URLRequest,
        redirectCount: Int,
        policy: CompatHTTPTransportPolicy
    ) throws -> URLRequest {
        guard redirectCount <= policy.maximumRedirects else {
            throw CompatHTTPTransportError.tooManyRedirects(limit: policy.maximumRedirects)
        }
        guard let destination = proposed.url else {
            throw CompatHTTPTransportError.invalidURL
        }
        _ = try CompatHTTPRequestEncoder.validatedURL(destination.absoluteString, policy: policy)
        if sourceURL.scheme?.lowercased() == "https",
           destination.scheme?.lowercased() == "http",
           !policy.allowsHTTPSDowngrade {
            throw CompatHTTPTransportError.insecureRedirect
        }

        var request = proposed
        request.timeoutInterval = policy.requestTimeoutSeconds
        if !CompatHTTPHeaderPolicy.sameOrigin(sourceURL, destination) {
            for name in CompatHTTPHeaderPolicy.sensitiveHeaderNames {
                request.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return request
    }
}

struct CompatHTTPResponseBuffer {
    let policy: CompatHTTPTransportPolicy
    private(set) var response: HTTPURLResponse?
    private(set) var headers: [CompatHTTPHeader] = []
    private var body = Data()

    init(policy: CompatHTTPTransportPolicy) {
        self.policy = policy
    }

    mutating func receive(_ response: HTTPURLResponse) throws {
        let normalized = response.allHeaderFields.map {
            CompatHTTPHeader(name: String(describing: $0.key), value: String(describing: $0.value))
        }.sorted {
            let lhs = $0.name.lowercased()
            let rhs = $1.name.lowercased()
            return lhs == rhs ? $0.value < $1.value : lhs < rhs
        }
        let headerBytes = normalized.reduce(32) {
            $0 + $1.name.utf8.count + $1.value.utf8.count + 4
        }
        guard headerBytes <= policy.maximumResponseHeaderBytes else {
            throw CompatHTTPTransportError.responseHeadersTooLarge(
                limit: policy.maximumResponseHeaderBytes
            )
        }
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(policy.maximumResponseBodyBytes) else {
            throw CompatHTTPTransportError.responseBodyTooLarge(
                limit: policy.maximumResponseBodyBytes
            )
        }
        self.response = response
        self.headers = normalized
    }

    mutating func append(_ data: Data) throws {
        guard data.count <= policy.maximumResponseBodyBytes - body.count else {
            throw CompatHTTPTransportError.responseBodyTooLarge(
                limit: policy.maximumResponseBodyBytes
            )
        }
        body.append(data)
    }

    func finish() throws -> CompatHTTPResponse {
        guard let response, let url = response.url else {
            throw CompatHTTPTransportError.invalidResponse
        }
        return CompatHTTPResponse(
            finalURL: url.absoluteString,
            statusCode: response.statusCode,
            headers: headers,
            body: [UInt8](body)
        )
    }
}

private final class CompatHTTPTaskRunner: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: CompatHTTPTransportPolicy
    private let protocolClasses: [AnyClass]?
    private let followsRedirects: Bool
    private let lock = NSLock()
    private var buffer: CompatHTTPResponseBuffer
    private var continuation: CheckedContinuation<CompatHTTPResponse, Swift.Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var redirectCount = 0
    private var terminalError: CompatHTTPTransportError?
    private var cancellationRequested = false
    private var finished = false

    init(
        policy: CompatHTTPTransportPolicy,
        protocolClasses: [AnyClass]?,
        followsRedirects: Bool
    ) {
        self.policy = policy
        self.protocolClasses = protocolClasses
        self.followsRedirects = followsRedirects
        self.buffer = CompatHTTPResponseBuffer(policy: policy)
    }

    func run(_ request: URLRequest) async throws -> CompatHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(request, continuation: continuation)
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    private func start(
        _ request: URLRequest,
        continuation: CheckedContinuation<CompatHTTPResponse, Swift.Error>
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = policy.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = policy.requestTimeoutSeconds
        configuration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)

        lock.lock()
        self.continuation = continuation
        self.session = session
        self.task = task
        let wasCancelled = cancellationRequested
        lock.unlock()

        if wasCancelled {
            complete(.failure(CompatHTTPTransportError.cancelled))
        } else {
            task.resume()
        }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        if terminalError == nil { terminalError = .cancelled }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: CompatHTTPTransportError) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func complete(_ result: Result<CompatHTTPResponse, Swift.Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.invalidResponse)
            completionHandler(.cancel)
            return
        }
        do {
            lock.lock()
            defer { lock.unlock() }
            try buffer.receive(http)
            completionHandler(.allow)
        } catch let error as CompatHTTPTransportError {
            fail(error)
            completionHandler(.cancel)
        } catch {
            fail(.invalidResponse)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            lock.lock()
            defer { lock.unlock() }
            try buffer.append(data)
        } catch let error as CompatHTTPTransportError {
            fail(error)
        } catch {
            fail(.invalidResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard followsRedirects else {
            completionHandler(nil)
            return
        }
        do {
            lock.lock()
            redirectCount += 1
            let count = redirectCount
            lock.unlock()
            guard let sourceURL = response.url else {
                throw CompatHTTPTransportError.invalidResponse
            }
            let sanitized = try CompatHTTPRedirectPolicy.sanitizedRequest(
                from: sourceURL,
                proposed: request,
                redirectCount: count,
                policy: policy
            )
            completionHandler(sanitized)
        } catch let error as CompatHTTPTransportError {
            completionHandler(nil)
            fail(error)
        } catch {
            completionHandler(nil)
            fail(.invalidResponse)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Swift.Error?
    ) {
        lock.lock()
        let terminal = terminalError
        lock.unlock()
        if let terminal {
            complete(.failure(terminal))
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: complete(.failure(CompatHTTPTransportError.cancelled))
            case .timedOut: complete(.failure(CompatHTTPTransportError.timedOut))
            default: complete(.failure(CompatHTTPTransportError.network(code: urlError.code.rawValue)))
            }
            return
        }
        if error != nil {
            complete(.failure(CompatHTTPTransportError.network(code: 0)))
            return
        }
        do {
            lock.lock()
            let response = try buffer.finish()
            lock.unlock()
            complete(.success(response))
        } catch let error as CompatHTTPTransportError {
            lock.unlock()
            complete(.failure(error))
        } catch {
            lock.unlock()
            complete(.failure(CompatHTTPTransportError.invalidResponse))
        }
    }
}
