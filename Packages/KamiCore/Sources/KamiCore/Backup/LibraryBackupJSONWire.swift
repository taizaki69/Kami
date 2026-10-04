import Foundation
import MihonCompatKit

private struct LibraryBackupJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct LibraryBackupJSONObject {
    let container: KeyedDecodingContainer<LibraryBackupJSONKey>

    init(_ decoder: Decoder, keys: Set<String>) throws {
        try Task.checkCancellation()
        container = try decoder.container(keyedBy: LibraryBackupJSONKey.self)
        let exactKeys = Set(keys.map { Data($0.utf8) })
        guard container.allKeys.allSatisfy({ exactKeys.contains(Data($0.stringValue.utf8)) }) else {
            throw LibraryBackupError.unknownSchemaKey
        }
    }

    func required<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        try container.decode(type, forKey: LibraryBackupJSONKey(key))
    }

    /// Optional means absent, not a null value with an invented default.
    func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        let codingKey = LibraryBackupJSONKey(key)
        guard container.contains(codingKey) else { return nil }
        return try container.decode(type, forKey: codingKey)
    }

    func integer(_ key: String) throws -> Int64 {
        let string: String
        do { string = try required(key) }
        catch { throw LibraryBackupError.invalidDecimalInteger }
        return try Self.decimal(string)
    }

    func optionalInteger(_ key: String) throws -> Int64? {
        guard container.contains(LibraryBackupJSONKey(key)) else { return nil }
        return try integer(key)
    }

    private static func decimal(_ value: String) throws -> Int64 {
        guard value.utf8.count <= 20, let integer = Int64(value),
              String(integer).utf8.elementsEqual(value.utf8) else {
            throw LibraryBackupError.invalidDecimalInteger
        }
        return integer
    }
}

struct LibraryBackupWireDocument: Decodable {
    let value: LibraryBackupDocument

    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: [
            "format", "version", "exportID", "exportedAt", "scope", "sources", "categories", "manga",
        ])
        let format: String = try object.required("format")
        let version: Int = try object.required("version")
        let scope: String = try object.required("scope")
        guard format == "kami.library", scope == "allStoredDomainRows" else { throw LibraryBackupError.invalidEnvelope }
        guard version == 1 else { throw LibraryBackupError.unsupportedVersion(version) }
        let exportString: String = try object.required("exportID")
        guard exportString.utf8.count == 36, let exportID = UUID(uuidString: exportString),
              exportID.uuidString.caseInsensitiveCompare(exportString) == .orderedSame else {
            throw LibraryBackupError.invalidEnvelope
        }
        let sources: [WireSource] = try object.required("sources")
        let categories: [WireCategory] = try object.required("categories")
        let manga: [WireManga] = try object.required("manga")
        value = LibraryBackupDocument(exportID: exportID, exportedAt: try object.integer("exportedAt"),
                                      sources: sources.map(\.value), categories: categories.map(\.value),
                                      manga: manga.map(\.value))
    }
}

private struct WireBinding: Decodable {
    let value: LibraryBackupDocument.ContentBinding
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: ["kind", "deploymentURL"])
        let kindString: String = try object.required("kind")
        guard let kind = LibraryBackupDocument.ContentBinding.Kind(rawValue: kindString) else {
            throw LibraryBackupError.invalidContentBinding
        }
        value = .init(kind: kind, deploymentURL: try object.optional("deploymentURL"))
    }
}

private struct WireSource: Decodable {
    let value: LibraryBackupDocument.Source
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: [
            "sourceID", "name", "language", "packageHint", "contentBinding",
        ])
        let binding: WireBinding = try object.required("contentBinding")
        value = .init(sourceID: try object.integer("sourceID"), name: try object.required("name"),
                      language: try object.optional("language"), packageHint: try object.optional("packageHint"),
                      contentBinding: binding.value)
    }
}

private struct WireCategory: Decodable {
    let value: LibraryBackupDocument.Category
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: ["key", "name", "sortOrder", "flags"])
        value = .init(key: try object.required("key"), name: try object.required("name"),
                      sortOrder: try object.integer("sortOrder"), flags: try object.integer("flags"))
    }
}

private struct WireManga: Decodable {
    let value: LibraryBackupDocument.Manga
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: [
            "sourceID", "url", "title", "altTitles", "thumbnailURL", "author", "artist", "descriptionText",
            "genres", "status", "inLibrary", "dateAdded", "dateUpdated", "lastFetched", "updateStrategy",
            "initialized", "categoryKeys", "chapters", "history", "discoveryBaseline", "knownChapters",
        ])
        let statusRaw: Int = try object.required("status")
        let strategyRaw: String = try object.required("updateStrategy")
        guard let status = MangaStatus(rawValue: statusRaw), let strategy = UpdateStrategy(rawValue: strategyRaw) else {
            throw LibraryBackupError.invalidSchema
        }
        let chapters: [WireChapter] = try object.required("chapters")
        let history: [WireHistory] = try object.required("history")
        let known: [WireKnownChapter] = try object.required("knownChapters")
        let baseline: WireBaseline? = try object.optional("discoveryBaseline")
        value = .init(sourceID: try object.integer("sourceID"), url: try object.required("url"),
                      title: try object.required("title"), altTitles: try object.required("altTitles"),
                      thumbnailURL: try object.optional("thumbnailURL"), author: try object.optional("author"),
                      artist: try object.optional("artist"), descriptionText: try object.optional("descriptionText"),
                      genres: try object.required("genres"), status: status, inLibrary: try object.required("inLibrary"),
                      dateAdded: try object.integer("dateAdded"), dateUpdated: try object.integer("dateUpdated"),
                      lastFetched: try object.integer("lastFetched"), updateStrategy: strategy,
                      initialized: try object.required("initialized"), categoryKeys: try object.required("categoryKeys"),
                      chapters: chapters.map(\.value), history: history.map(\.value),
                      discoveryBaseline: baseline?.value, knownChapters: known.map(\.value))
    }
}

private struct WireChapter: Decodable {
    let value: LibraryBackupDocument.Chapter
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: [
            "sourceOrder", "url", "name", "scanlator", "number", "dateUpload", "dateFetch", "read",
            "bookmark", "lastPageRead", "isCurrent",
        ])
        value = .init(sourceOrder: try object.integer("sourceOrder"), url: try object.required("url"),
                      name: try object.required("name"), scanlator: try object.optional("scanlator"),
                      number: try object.required("number"), dateUpload: try object.integer("dateUpload"),
                      dateFetch: try object.integer("dateFetch"), read: try object.required("read"),
                      bookmark: try object.required("bookmark"), lastPageRead: try object.integer("lastPageRead"),
                      isCurrent: try object.required("isCurrent"))
    }
}

private struct WireHistory: Decodable {
    let value: LibraryBackupDocument.History
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: ["chapterURL", "lastRead", "readDuration"])
        value = .init(chapterURL: try object.required("chapterURL"), lastRead: try object.integer("lastRead"),
                      readDuration: try object.integer("readDuration"))
    }
}

private struct WireBaseline: Decodable {
    let value: LibraryBackupDocument.DiscoveryBaseline
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: ["establishedAt"])
        value = .init(establishedAt: try object.integer("establishedAt"))
    }
}

private struct WireKnownChapter: Decodable {
    let value: LibraryBackupDocument.KnownChapter
    init(from decoder: Decoder) throws {
        let object = try LibraryBackupJSONObject(decoder, keys: ["url", "firstSeen", "detectedAt"])
        value = .init(url: try object.required("url"), firstSeen: try object.integer("firstSeen"),
                      detectedAt: try object.optionalInteger("detectedAt"))
    }
}

/// Appends only after checking the remaining output budget. Canonical ordering
/// applies to identity-bearing row sets; alternate titles and genres retain
/// their stored sequence. JSON object keys are emitted in ASCII sorted order.
struct LibraryBackupJSONWriter {
    private(set) var data = Data()
    private let policy: LibraryBackupPolicy
    private var nextCancellationCheck = 0

    init(policy: LibraryBackupPolicy) { self.policy = policy }

    private mutating func append(_ byte: UInt8) throws {
        guard data.count < policy.maximumInputBytes else { throw LibraryBackupError.limitExceeded(.inputBytes) }
        if data.count >= nextCancellationCheck {
            try Task.checkCancellation()
            nextCancellationCheck = data.count + 2_048
        }
        data.append(byte)
    }

    private mutating func raw(_ value: String) throws {
        guard value.utf8.count <= policy.maximumInputBytes - data.count else {
            throw LibraryBackupError.limitExceeded(.inputBytes)
        }
        for byte in value.utf8 { try append(byte) }
    }

    private mutating func string(_ value: String) throws {
        try append(0x22)
        let hex = Array("0123456789abcdef".utf8)
        for byte in value.utf8 {
            switch byte {
            case 0x22, 0x5C: try append(0x5C); try append(byte)
            case 0x08: try raw("\\b")
            case 0x09: try raw("\\t")
            case 0x0A: try raw("\\n")
            case 0x0C: try raw("\\f")
            case 0x0D: try raw("\\r")
            case 0x00...0x1F:
                try raw("\\u00")
                try append(hex[Int(byte >> 4)])
                try append(hex[Int(byte & 0x0F)])
            default: try append(byte)
            }
        }
        try append(0x22)
    }

    private mutating func key(_ name: String, first: inout Bool) throws {
        if !first { try append(0x2C) }
        first = false
        try string(name)
        try append(0x3A)
    }

    private mutating func field(_ name: String, _ value: String, first: inout Bool) throws {
        try key(name, first: &first)
        try string(value)
    }

    private mutating func field(_ name: String, _ value: Int64, first: inout Bool) throws {
        try field(name, String(value), first: &first)
    }

    private mutating func field(_ name: String, _ value: Bool, first: inout Bool) throws {
        try key(name, first: &first)
        try raw(value ? "true" : "false")
    }

    private mutating func optional(_ name: String, _ value: String?, first: inout Bool) throws {
        if let value { try field(name, value, first: &first) }
    }

    private mutating func array<T>(_ values: [T], write: (inout Self, T) throws -> Void) throws {
        try append(0x5B)
        for index in values.indices {
            try Task.checkCancellation()
            if index > 0 { try append(0x2C) }
            try write(&self, values[index])
        }
        try append(0x5D)
    }

    private static func bytesBefore(_ first: String, _ second: String) -> Bool {
        first.utf8.lexicographicallyPrecedes(second.utf8)
    }

    mutating func write(_ document: LibraryBackupDocument) throws {
        try Task.checkCancellation()
        try append(0x7B)
        var first = true
        try key("categories", first: &first)
        let categories = try document.categories.sorted {
            try Task.checkCancellation()
            return $0.sortOrder == $1.sortOrder ? Self.bytesBefore($0.key, $1.key) : $0.sortOrder < $1.sortOrder
        }
        try array(categories) { try $0.write($1) }
        try field("exportID", document.exportID.uuidString, first: &first)
        try field("exportedAt", document.exportedAt, first: &first)
        try field("format", document.format, first: &first)
        try key("manga", first: &first)
        let manga = try document.manga.sorted {
            try Task.checkCancellation()
            return $0.sourceID == $1.sourceID ? Self.bytesBefore($0.url, $1.url) : $0.sourceID < $1.sourceID
        }
        try array(manga) { try $0.write($1) }
        try field("scope", document.scope.rawValue, first: &first)
        try key("sources", first: &first)
        let sources = try document.sources.sorted {
            try Task.checkCancellation()
            return $0.sourceID < $1.sourceID
        }
        try array(sources) { try $0.write($1) }
        try key("version", first: &first)
        try raw(String(document.version))
        try append(0x7D)
        try Task.checkCancellation()
    }

    private mutating func write(_ value: LibraryBackupDocument.ContentBinding) throws {
        try append(0x7B)
        var first = true
        try optional("deploymentURL", value.deploymentURL, first: &first)
        try field("kind", value.kind.rawValue, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.Source) throws {
        try append(0x7B)
        var first = true
        try key("contentBinding", first: &first)
        try write(value.contentBinding)
        try optional("language", value.language, first: &first)
        try field("name", value.name, first: &first)
        try optional("packageHint", value.packageHint, first: &first)
        try field("sourceID", value.sourceID, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.Category) throws {
        try append(0x7B)
        var first = true
        try field("flags", value.flags, first: &first)
        try field("key", value.key, first: &first)
        try field("name", value.name, first: &first)
        try field("sortOrder", value.sortOrder, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.Manga) throws {
        try append(0x7B)
        var first = true
        try key("altTitles", first: &first)
        try array(value.altTitles) { try $0.string($1) }
        try optional("artist", value.artist, first: &first)
        try optional("author", value.author, first: &first)
        try key("categoryKeys", first: &first)
        let memberships = try value.categoryKeys.sorted { first, second in
            try Task.checkCancellation()
            return Self.bytesBefore(first, second)
        }
        try array(memberships) { try $0.string($1) }
        try key("chapters", first: &first)
        let chapters = try value.chapters.sorted {
            try Task.checkCancellation()
            return $0.sourceOrder == $1.sourceOrder ? Self.bytesBefore($0.url, $1.url) : $0.sourceOrder < $1.sourceOrder
        }
        try array(chapters) { try $0.write($1) }
        try field("dateAdded", value.dateAdded, first: &first)
        try field("dateUpdated", value.dateUpdated, first: &first)
        try optional("descriptionText", value.descriptionText, first: &first)
        if let baseline = value.discoveryBaseline {
            try key("discoveryBaseline", first: &first)
            try append(0x7B)
            var baselineFirst = true
            try field("establishedAt", baseline.establishedAt, first: &baselineFirst)
            try append(0x7D)
        }
        try key("genres", first: &first)
        try array(value.genres) { try $0.string($1) }
        try key("history", first: &first)
        let history = try value.history.sorted {
            try Task.checkCancellation()
            return Self.bytesBefore($0.chapterURL, $1.chapterURL)
        }
        try array(history) { try $0.write($1) }
        try field("inLibrary", value.inLibrary, first: &first)
        try field("initialized", value.initialized, first: &first)
        try key("knownChapters", first: &first)
        let known = try value.knownChapters.sorted {
            try Task.checkCancellation()
            return Self.bytesBefore($0.url, $1.url)
        }
        try array(known) { try $0.write($1) }
        try field("lastFetched", value.lastFetched, first: &first)
        try field("sourceID", value.sourceID, first: &first)
        try key("status", first: &first)
        try raw(String(value.status.rawValue))
        try optional("thumbnailURL", value.thumbnailURL, first: &first)
        try field("title", value.title, first: &first)
        try field("updateStrategy", value.updateStrategy.rawValue, first: &first)
        try field("url", value.url, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.Chapter) throws {
        try append(0x7B)
        var first = true
        try field("bookmark", value.bookmark, first: &first)
        try field("dateFetch", value.dateFetch, first: &first)
        try field("dateUpload", value.dateUpload, first: &first)
        try field("isCurrent", value.isCurrent, first: &first)
        try field("lastPageRead", value.lastPageRead, first: &first)
        try field("name", value.name, first: &first)
        try key("number", first: &first)
        try raw(String(value.number))
        try field("read", value.read, first: &first)
        try optional("scanlator", value.scanlator, first: &first)
        try field("sourceOrder", value.sourceOrder, first: &first)
        try field("url", value.url, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.History) throws {
        try append(0x7B)
        var first = true
        try field("chapterURL", value.chapterURL, first: &first)
        try field("lastRead", value.lastRead, first: &first)
        try field("readDuration", value.readDuration, first: &first)
        try append(0x7D)
    }

    private mutating func write(_ value: LibraryBackupDocument.KnownChapter) throws {
        try append(0x7B)
        var first = true
        if let detectedAt = value.detectedAt { try field("detectedAt", detectedAt, first: &first) }
        try field("firstSeen", value.firstSeen, first: &first)
        try field("url", value.url, first: &first)
        try append(0x7D)
    }
}
