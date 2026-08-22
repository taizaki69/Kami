import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Normalized view over both extension-store index formats:
/// legacy JSON (`index.min.json`) and the new protobuf index (`index.pb`).
public struct ExtensionRepositoryIndex: Equatable, Sendable {
    enum ParseError: Swift.Error {
        case indexTooLarge(Int)
    }

    static let maximumIndexSize = 32 * 1024 * 1024

    public struct Source: Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let language: String
        public let homeURL: String
        public let mirrors: [String]
        public let message: String?
    }

    public struct Extension: Equatable, Sendable {
        public enum ContentWarning: Int, Sendable {
            case unspecified = 0, safe = 1, mixed = 2, nsfw = 3
        }

        public let name: String
        public let packageName: String
        public let versionName: String
        public let versionCode: Int64
        public let extensionLib: String
        public let contentWarning: ContentWarning
        public let apkURL: String
        public let iconURL: String?
        public let sources: [Source]

        /// Legacy-format entries list APK filename relative to the index URL.
        public init(fromLegacy entry: LegacyIndexEntry, baseURL: URL) {
            name = entry.name
            packageName = entry.pkg
            versionName = entry.version
            versionCode = Int64(entry.code)
            extensionLib = "" // not present in the legacy format
            contentWarning = entry.nsfw == 1 ? .nsfw : .mixed
            apkURL = baseURL.deletingLastPathComponent().appendingPathComponent(entry.apk).absoluteString
            iconURL = nil
            sources = entry.sources.map {
                Source(id: Int64($0.id) ?? 0, name: $0.name, language: $0.lang, homeURL: $0.baseUrl, mirrors: [], message: nil)
            }
        }

        /// New protobuf format (tachiyomix index.proto).
        public init(fromProto message: ProtoMessage) {
            name = message.string(1) ?? ""
            packageName = message.string(2) ?? ""
            let resources = message.message(3)
            apkURL = resources?.string(1) ?? ""
            iconURL = resources?.string(2)
            extensionLib = message.string(4) ?? ""
            versionCode = message.int64(5) ?? 0
            versionName = message.string(6) ?? ""
            contentWarning = ContentWarning(rawValue: message.int(7) ?? 0) ?? .unspecified
            sources = message.messages(8).map { src in
                Source(
                    id: src.int64(1) ?? 0,
                    name: src.string(2) ?? "",
                    language: src.string(3) ?? "",
                    homeURL: src.string(4) ?? "",
                    mirrors: src.strings(5),
                    message: src.string(7)
                )
            }
        }
    }

    public let storeName: String
    public let badgeLabel: String?
    public let signingKey: String?
    public let extensions: [Extension]

    /// Set when the store index referenced `extensionListUrl` instead of an
    /// inline list. `ExtensionStoreClient` chases this URL automatically.
    public let externalListURL: URL?

    public init(storeName: String, badgeLabel: String?, signingKey: String?, extensions: [Extension], externalListURL: URL? = nil) {
        self.storeName = storeName
        self.badgeLabel = badgeLabel
        self.signingKey = signingKey
        self.extensions = extensions
        self.externalListURL = externalListURL
    }

    /// Detects and parses either format from raw bytes fetched at `url`.
    /// gzip-wrapped payloads (GitHub raw serves these) are unwrapped first.
    public init(bytes rawBytes: [UInt8], url: URL) throws {
        guard rawBytes.count <= Self.maximumIndexSize else {
            throw ParseError.indexTooLarge(Self.maximumIndexSize)
        }
        let bytes = (rawBytes.count > 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b)
            ? try Gzip.decompress(rawBytes, outputLimit: Self.maximumIndexSize)
            : rawBytes

        // The new index is a protobuf `Index` message. Legacy index is JSON.
        // Distinguish: protobuf `Index` starts with field 1 (name, string):
        // tag byte 0x0A. JSON starts with '[' or '{' (with whitespace).
        let firstNonSpace = bytes.first { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }
        if firstNonSpace == UInt8(ascii: "[") || firstNonSpace == UInt8(ascii: "{") {
            let legacy = try JSONDecoder().decode([LegacyIndexEntry].self, from: Data(bytes))
            self.storeName = url.host ?? "Extension repository"
            self.badgeLabel = nil
            self.signingKey = nil
            self.extensions = legacy.map { Extension(fromLegacy: $0, baseURL: url) }
            self.externalListURL = nil
            return
        }

        let index = try ProtoMessage(bytes)
        // ExtensionList lives at field 101 (oneof `extensions`).
        var list: [Extension] = []
        var external: URL?
        if let inline = index.message(101) {
            list = inline.messages(1).map { Extension(fromProto: $0) }
        } else if let listURLString = index.string(102), let listURL = URL(string: listURLString) {
            external = listURL
        }
        self.storeName = index.string(1) ?? "Extension store"
        self.badgeLabel = index.string(2)
        self.signingKey = index.string(3)
        self.extensions = list
        self.externalListURL = external
    }
}

/// Legacy `index.min.json` entry schema (keiyoushi et al.).
public struct LegacyIndexEntry: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let name: String
        public let lang: String
        public let id: String
        public let baseUrl: String
    }

    public let name: String
    public let pkg: String
    public let apk: String
    public let lang: String
    public let code: Int
    public let version: String
    public let nsfw: Int
    public let sources: [Source]
}

extension ExtensionRepositoryIndex {
    /// Parses the external extension list (`ExtensionList` protobuf message).
    public static func parseExternalList(_ bytes: [UInt8]) throws -> [Extension] {
        guard bytes.count <= Self.maximumIndexSize else {
            throw ParseError.indexTooLarge(Self.maximumIndexSize)
        }
        let list = try ProtoMessage(bytes)
        return list.messages(1).map { Extension(fromProto: $0) }
    }
}

/// HTTP client for extension stores. URLSession-based; both index formats are
/// negotiated transparently, and `extensionListUrl` indirection is chased.
public actor ExtensionStoreClient {
    public enum FetchError: Swift.Error {
        case badURL(String)
        case transport(Swift.Error)
        case http(Int)
        case badIndex(String)
        case responseTooLarge(Int)
    }

    private static let maximumAPKSize = 128 * 1024 * 1024
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and parses a store index from a user-supplied URL. Accepts:
    /// direct `index.min.json`/`index.json` URLs (legacy) or an `index.pb`
    /// / store root URL (new format).
    public func fetchIndex(_ urlText: String) async throws -> ExtensionRepositoryIndex {
        guard let url = normalizedIndexURL(urlText) else {
            throw FetchError.badURL(urlText)
        }
        let (data, response) = try await get(url)
        try check(response)
        guard data.count <= ExtensionRepositoryIndex.maximumIndexSize else {
            throw FetchError.responseTooLarge(ExtensionRepositoryIndex.maximumIndexSize)
        }
        var index = try ExtensionRepositoryIndex(bytes: [UInt8](data), url: url)
        if let external = index.externalListURL {
            let (listData, listResponse) = try await get(external)
            try check(listResponse)
            guard listData.count <= ExtensionRepositoryIndex.maximumIndexSize else {
                throw FetchError.responseTooLarge(ExtensionRepositoryIndex.maximumIndexSize)
            }
            let extensions = try ExtensionRepositoryIndex.parseExternalList([UInt8](listData))
            index = ExtensionRepositoryIndex(
                storeName: index.storeName,
                badgeLabel: index.badgeLabel,
                signingKey: index.signingKey,
                extensions: extensions,
                externalListURL: nil
            )
        }
        return index
    }

    public func download(apkURL: String) async throws -> [UInt8] {
        guard let url = URL(string: apkURL) else { throw FetchError.badURL(apkURL) }
        let (data, response) = try await get(url)
        try check(response)
        guard data.count <= Self.maximumAPKSize else {
            throw FetchError.responseTooLarge(Self.maximumAPKSize)
        }
        return [UInt8](data)
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        // Completion-based request wrapped in a continuation: the async
        // URLSession.data(from:) conveniences are Darwin-only.
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: FetchError.transport(error))
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: FetchError.badIndex("HTTP response was missing"))
                }
            }.resume()
        }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(http.statusCode)
        }
    }

    private func normalizedIndexURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.hasPrefix("http://") && !candidate.hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate) else { return nil }
        // A bare store URL gets the standard index name appended.
        if url.lastPathComponent != "index.min.json"
            && url.lastPathComponent != "index.json"
            && url.lastPathComponent != "index.pb" {
            return url.appendingPathComponent("index.pb")
        }
        return url
    }
}
