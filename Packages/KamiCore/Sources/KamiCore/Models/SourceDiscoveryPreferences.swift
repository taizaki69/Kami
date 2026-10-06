import Foundation

public enum SourceDiscoveryPreferencesError: Error, Equatable, Sendable, LocalizedError {
    case invalidDocument, invalidSelection, staleSelection, persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "The saved source selection could not be read. Review your selection before searching."
        case .invalidSelection: "This source selection exceeds the supported limits."
        case .staleSelection: "The source selection changed. Reload it before applying your edits."
        case .persistenceUnavailable: "The source selection could not be confirmed. Review it and try again."
        }
    }
}

/// Discovery preferences only: these values never register, enable or trust a
/// source. nil means all, while an empty allowlist deliberately means none.
public struct SourceDiscoveryPreferences: Equatable, Sendable, Codable {
    public static let maximumSourceIDs = 4_096
    public static let maximumLanguages = 256
    public static let maximumBytes = 128 * 1_024
    public static let all = Self()
    public static let none = Self(sourceIDs: [], languages: nil, validated: ())

    public let sourceIDs: Set<Int64>?
    public let languages: Set<String>?

    public init() { sourceIDs = nil; languages = nil }

    public init(sourceIDs: Set<Int64>?, languages: Set<String>?) throws {
        guard (sourceIDs?.count ?? 0) <= Self.maximumSourceIDs,
              (languages?.count ?? 0) <= Self.maximumLanguages else {
            throw SourceDiscoveryPreferencesError.invalidSelection
        }
        var normalized: Set<String>?
        if let languages {
            normalized = []
            for language in languages {
                guard let tag = Self.languageKey(language) else {
                    throw SourceDiscoveryPreferencesError.invalidSelection
                }
                normalized?.insert(tag)
            }
        }
        self.init(sourceIDs: sourceIDs, languages: normalized, validated: ())
    }

    private init(sourceIDs: Set<Int64>?, languages: Set<String>?, validated: Void) {
        self.sourceIDs = sourceIDs
        self.languages = languages
    }

    /// Language tags compare without ASCII case; regional tags remain distinct.
    /// "all" is a source's multi-language tag, not a wildcard for other tags.
    public static func languageKey(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({
                  (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                      || (0x30...0x39).contains($0) || $0 == 0x2d
              }), !value.split(separator: "-", omittingEmptySubsequences: false).contains("") else { return nil }
        return value.lowercased()
    }

    public func includes(sourceID: Int64, language: String) -> Bool {
        guard sourceIDs?.contains(sourceID) ?? true else { return false }
        guard let languages else { return true }
        guard let key = Self.languageKey(language) else { return false }
        return languages.contains(key)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw SourceDiscoveryPreferencesError.invalidDocument }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SourceDiscoveryPreferencesError.invalidDocument }
        do {
            // Reuse the bounded lexical validator before Codable can collapse
            // repeated/escaped keys or allocate an arbitrary JSON tree.
            let policy = try LibraryBackupPolicy(maximumInputBytes: maximumBytes, maximumDepth: 3,
                maximumJSONValues: 4 + maximumSourceIDs + maximumLanguages,
                maximumJSONStringBytes: maximumBytes, maximumJSONObjectKeys: 3,
                maximumJSONArrayElements: maximumSourceIDs)
            var lexical = try LibraryBackupJSONPreflight(data: data, policy: policy)
            try lexical.run()
            return try JSONDecoder().decode(Self.self, from: data)
        }
        catch { throw SourceDiscoveryPreferencesError.invalidDocument }
    }

    private enum CodingKeys: String, CodingKey { case version, sourceIDs, languages }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == ["version", "sourceIDs", "languages"] else {
            throw SourceDiscoveryPreferencesError.invalidDocument
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else {
            throw SourceDiscoveryPreferencesError.invalidDocument
        }
        let ids = try c.decode([String]?.self, forKey: .sourceIDs)
        let tags = try c.decode([String]?.self, forKey: .languages)
        guard (ids?.count ?? 0) <= Self.maximumSourceIDs,
              (tags?.count ?? 0) <= Self.maximumLanguages else {
            throw SourceDiscoveryPreferencesError.invalidDocument
        }
        var parsedIDs: Set<Int64>?
        if let ids {
            parsedIDs = []
            for raw in ids {
                guard let id = Int64(raw), String(id) == raw,
                      parsedIDs?.insert(id).inserted == true else {
                    throw SourceDiscoveryPreferencesError.invalidDocument
                }
            }
        }
        try self.init(sourceIDs: parsedIDs, languages: tags.map(Set.init))
        guard languages?.count == tags?.count else { throw SourceDiscoveryPreferencesError.invalidDocument }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version)
        // Strings preserve every signed Int64 even in JSON consumers using Double.
        try c.encode(sourceIDs.map { $0.sorted().map(String.init) }, forKey: .sourceIDs)
        try c.encode(languages.map { $0.sorted() }, forKey: .languages)
    }
}
