/// Transport-neutral HTTP values produced by the OkHttp compatibility layer.
/// Building these values has no network side effects. They cross the explicit
/// `CompatHTTPTransport` boundary only when a caller supplies a source-scoped
/// transport; interpreted `awaitSuccess` is not wired to that boundary yet.
public struct CompatHTTPHeader: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CompatHTTPFormField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum CompatHTTPRequestBody: Sendable, Equatable {
    case form(fields: [CompatHTTPFormField])
    case text(value: String, mediaType: String?)
}

public struct CompatHTTPCachePolicy: Sendable, Equatable {
    public var maxAgeSeconds: Int?

    public init(maxAgeSeconds: Int? = nil) {
        self.maxAgeSeconds = maxAgeSeconds
    }
}

public struct CompatHTTPRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [CompatHTTPHeader]
    public var body: CompatHTTPRequestBody?
    public var cachePolicy: CompatHTTPCachePolicy?

    public init(url: String,
                method: String = "GET",
                headers: [CompatHTTPHeader] = [],
                body: CompatHTTPRequestBody? = nil,
                cachePolicy: CompatHTTPCachePolicy? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.cachePolicy = cachePolicy
    }
}
