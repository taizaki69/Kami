import Foundation

/// Bounded library-data reader for Mihon/Tachiyomi protobuf backups.
///
/// Mihon main 7aacaa349019ff42b8b05403d8beebe94c8f6dfc and v0.20.4
/// write gzip; their decoder also accepts raw protobuf. This reader interprets
/// library identities, categories, chapters, history and source descriptions.
/// Preferences, trackers, repository declarations and other unsupported fields
/// are counted as opaque input. Decoding never supplies source or repo trust.
public struct TachibkReader: Sendable {
    public enum Compression: String, Sendable, Equatable {
        case rawProtobuf, gzip
    }

    public enum Scope: Int, CaseIterable, Sendable, Hashable {
        case root, manga, category, source, chapter, history
    }

    public enum UnsupportedFeature: Int, CaseIterable, Sendable, Hashable {
        case appPreferences, sourcePreferences, extensionStores, tracking
        case readerSettings, chapterSettings, excludedScanlators, notes
        case mangaMemo, chapterMemo, synchronizationMetadata
        case legacySources, legacyHistory, unknownField
    }

    /// Each item counts wire-field occurrences, not guessed nested elements.
    /// Bytes count the skipped value (LEN contents or scalar bytes), excluding
    /// its tag and LEN prefix. The scope/feature space is finite; attacker-chosen
    /// field numbers and skipped preference strings are never report keys.
    public struct CoverageItem: Sendable, Equatable {
        public let scope: Scope
        public let feature: UnsupportedFeature
        public let occurrences: Int
        public let valueBytes: Int
    }

    public struct CoverageReport: Sendable, Equatable {
        /// Sorted by scope, then feature for stable reports.
        public let unsupported: [CoverageItem]

        public var unsupportedOccurrences: Int {
            unsupported.reduce(0) { $0 + $1.occurrences }
        }

        public var unsupportedValueBytes: Int {
            unsupported.reduce(0) { $0 + $1.valueBytes }
        }

        public func occurrences(of feature: UnsupportedFeature, in scope: Scope) -> Int {
            unsupported.first { $0.scope == scope && $0.feature == feature }?.occurrences ?? 0
        }
    }

    public struct DecodedBackup: Sendable, Equatable {
        public let compression: Compression
        public let manga: [BackupManga]
        public let categories: [BackupCategory]
        public let sources: [BackupSource]
        public let coverage: CoverageReport
    }

    /// Compatibility projection of `decode`. The category order was widened
    /// from Int to Int64, and coverage is always appended. Use `decode` to retain
    /// category IDs/flags and the container type. String preferences and store
    /// names are deliberately not produced from unsupported protobuf messages.
    public enum BackupEntry: Sendable, Equatable {
        case manga(BackupManga)
        case category(name: String, order: Int64)
        case source(id: Int64, name: String)
        case coverage(CoverageReport)
        @available(*, deprecated, message: "Preferences are opaque; inspect decode().coverage.")
        case preference(key: String, value: String)
        @available(*, deprecated, message: "Repository declarations are opaque; inspect decode().coverage.")
        case extensionStore(name: String)
        @available(*, deprecated, message: "Unknown fields are counted by scope in decode().coverage.")
        case unknown(field: Int)
    }

    public enum BackupUpdateStrategy: Int, Sendable, Equatable {
        case alwaysUpdate = 0, onlyFetchOnce = 1
    }

    public struct BackupManga: Sendable, Equatable {
        public let url: String
        public let title: String
        public let artist: String?
        public let author: String?
        public let descriptionText: String?
        public let genre: [String]
        public let status: Int
        public let sourceId: Int64
        public let favorite: Bool
        public let thumbnailURL: String?
        /// Upstream epoch milliseconds; 0 means no recorded date.
        public let dateAdded: Int64
        /// Historical upstream seconds. Kept separately without conversion.
        public let favoriteModifiedAt: Int64?
        public let updateStrategy: BackupUpdateStrategy
        public let initialized: Bool
        /// References to BackupCategory.order, not BackupCategory.id.
        public let categories: [Int64]
        public let chapters: [BackupChapter]
        public let history: [BackupHistory]
        public var chapterCount: Int { chapters.count }
    }

    public struct BackupCategory: Sendable, Equatable {
        public let name: String
        public let order: Int64
        public let id: Int64
        public let flags: Int64
    }

    public struct BackupSource: Sendable, Equatable {
        public let id: Int64
        public let name: String
    }

    public struct BackupChapter: Sendable, Equatable {
        public let url: String
        public let name: String
        public let scanlator: String?
        public let read: Bool
        public let bookmark: Bool
        public let lastPageRead: Int64
        public let dateFetch: Int64
        public let dateUpload: Int64
        public let chapterNumber: Float
        public let sourceOrder: Int64
    }

    public struct BackupHistory: Sendable, Equatable {
        public let url: String
        /// Upstream epoch milliseconds, including 0 for removed history.
        public let lastRead: Int64
        public let readDuration: Int64
    }

    public enum Limit: String, Sendable, Hashable {
        case inputBytes, payloadBytes, fields, manga, categories, sources
        case chapters, history, categoryReferences, stringBytes
        case stringLength, urlLength, descriptionLength, depth
    }

    /// Immutable limits. Defaults are also hard maxima: callers may only lower
    /// them. Counts and string-byte usage are cumulative over the entire backup,
    /// including overwritten singular values. Opaque contents are not recursively
    /// interpreted; their outer fields and bytes remain bounded by the payload.
    public struct Policy: Sendable, Equatable {
        public let maximumInputBytes: Int
        public let maximumPayloadBytes: Int
        public let maximumFields: Int
        public let maximumManga: Int
        public let maximumCategories: Int
        public let maximumSources: Int
        public let maximumChapters: Int
        public let maximumHistory: Int
        public let maximumCategoryReferences: Int
        public let maximumStringBytes: Int
        public let maximumStringLengthBytes: Int
        public let maximumURLBytes: Int
        public let maximumDescriptionBytes: Int
        public let maximumDepth: Int

        public static let `default` = Policy()

        public init(
            maximumInputBytes: Int = 32 * 1024 * 1024,
            maximumPayloadBytes: Int = 64 * 1024 * 1024,
            maximumFields: Int = 500_000,
            maximumManga: Int = 10_000,
            maximumCategories: Int = 1_000,
            maximumSources: Int = 10_000,
            maximumChapters: Int = 100_000,
            maximumHistory: Int = 100_000,
            maximumCategoryReferences: Int = 100_000,
            maximumStringBytes: Int = 32 * 1024 * 1024,
            maximumStringLengthBytes: Int = 256 * 1024,
            maximumURLBytes: Int = 4 * 1024,
            maximumDescriptionBytes: Int = 256 * 1024,
            maximumDepth: Int = 8
        ) {
            self.maximumInputBytes = maximumInputBytes
            self.maximumPayloadBytes = maximumPayloadBytes
            self.maximumFields = maximumFields
            self.maximumManga = maximumManga
            self.maximumCategories = maximumCategories
            self.maximumSources = maximumSources
            self.maximumChapters = maximumChapters
            self.maximumHistory = maximumHistory
            self.maximumCategoryReferences = maximumCategoryReferences
            self.maximumStringBytes = maximumStringBytes
            self.maximumStringLengthBytes = maximumStringLengthBytes
            self.maximumURLBytes = maximumURLBytes
            self.maximumDescriptionBytes = maximumDescriptionBytes
            self.maximumDepth = maximumDepth
        }

        func validate() throws {
            let checks: [(Limit, Int, Int)] = [
                (.inputBytes, maximumInputBytes, Self.default.maximumInputBytes),
                (.payloadBytes, maximumPayloadBytes, Self.default.maximumPayloadBytes),
                (.fields, maximumFields, Self.default.maximumFields),
                (.manga, maximumManga, Self.default.maximumManga),
                (.categories, maximumCategories, Self.default.maximumCategories),
                (.sources, maximumSources, Self.default.maximumSources),
                (.chapters, maximumChapters, Self.default.maximumChapters),
                (.history, maximumHistory, Self.default.maximumHistory),
                (.categoryReferences, maximumCategoryReferences, Self.default.maximumCategoryReferences),
                (.stringBytes, maximumStringBytes, Self.default.maximumStringBytes),
                (.stringLength, maximumStringLengthBytes, Self.default.maximumStringLengthBytes),
                (.urlLength, maximumURLBytes, Self.default.maximumURLBytes),
                (.descriptionLength, maximumDescriptionBytes, Self.default.maximumDescriptionBytes),
                (.depth, maximumDepth, Self.default.maximumDepth),
            ]
            for (limit, value, maximum) in checks {
                guard value >= 0, value <= maximum else { throw Error.invalidPolicy(limit) }
            }
        }
    }

    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        case zstdNotSupported
        case zlibNotSupported
        case legacyJSONNotSupported
        case invalidPolicy(Limit)
        case limitExceeded(Limit)
        case malformedProtobuf(offset: Int)
        case invalidFieldNumber(scope: Scope)
        case unsupportedWireType(scope: Scope, wire: Int)
        case wrongWireType(scope: Scope, field: Int, wire: Int)
        case missingRequiredField(scope: Scope, field: Int)
        case emptyIdentity(scope: Scope, field: Int)
        case invalidUTF8(scope: Scope, field: Int)
        case invalidInteger(scope: Scope, field: Int)
        case invalidBoolean(scope: Scope, field: Int)
        case invalidFloat(scope: Scope, field: Int)
        case invalidUpdateStrategy(Int64)

        public var description: String {
            switch self {
            case .zstdNotSupported: return "zstd-compressed backups are not supported"
            case .zlibNotSupported: return "zlib-wrapped backups are not supported; the verified Mihon format uses gzip"
            case .legacyJSONNotSupported: return "legacy JSON backups are not supported"
            case let .invalidPolicy(limit): return "invalid backup policy for \(limit.rawValue)"
            case let .limitExceeded(limit): return "backup exceeds the \(limit.rawValue) limit"
            case let .malformedProtobuf(offset): return "malformed backup protobuf at byte \(offset)"
            case let .invalidFieldNumber(scope): return "invalid protobuf field number in \(scope)"
            case let .unsupportedWireType(scope, wire): return "unsupported protobuf wire type \(wire) in \(scope)"
            case let .wrongWireType(scope, field, wire): return "wrong wire type \(wire) for \(scope) field \(field)"
            case let .missingRequiredField(scope, field): return "missing required \(scope) field \(field)"
            case let .emptyIdentity(scope, field): return "empty identity in \(scope) field \(field)"
            case let .invalidUTF8(scope, field): return "invalid UTF-8 in \(scope) field \(field)"
            case let .invalidInteger(scope, field): return "integer out of range in \(scope) field \(field)"
            case let .invalidBoolean(scope, field): return "invalid boolean in \(scope) field \(field)"
            case let .invalidFloat(scope, field): return "non-finite float in \(scope) field \(field)"
            case let .invalidUpdateStrategy(value): return "unsupported backup update strategy \(value)"
            }
        }
    }

    public let policy: Policy

    public init(policy: Policy = .default) { self.policy = policy }

    /// Decode the supported schema with a coverage report. An empty protobuf
    /// message is an empty backup; no leading field order is required. Known
    /// singular fields use their last occurrence. Any wrong wire type or invalid
    /// consumed nested message fails the whole decode. Unsupported message
    /// contents are skipped opaquely and explicitly reported, not validated.
    public func decode(_ bytes: [UInt8]) throws -> DecodedBackup {
        try Task.checkCancellation()
        try policy.validate()
        guard bytes.count <= policy.maximumInputBytes else { throw Error.limitExceeded(.inputBytes) }

        let payload: [UInt8]
        let compression: Compression
        if bytes.starts(with: [0x1f, 0x8b]) {
            do {
                payload = try Gzip.decompressSingleMember(bytes, outputLimit: policy.maximumPayloadBytes)
            } catch Inflate.Error.outputLimitExceeded(_) {
                throw Error.limitExceeded(.payloadBytes)
            }
            compression = .gzip
        } else {
            payload = bytes
            compression = .rawProtobuf
        }
        try Task.checkCancellation()
        guard payload.count <= policy.maximumPayloadBytes else { throw Error.limitExceeded(.payloadBytes) }
        do {
            return try BackupWireDecoder(policy: policy).decode(payload, compression: compression)
        } catch let error as Error {
            // zlib and zstd magic can also begin valid unknown protobuf fields.
            // A successful raw parse wins; format hints classify only failures.
            // Limits and CancellationError always retain their own meaning.
            guard compression == .rawProtobuf else { throw error }
            if case .limitExceeded = error { throw error }
            if bytes.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { throw Error.zstdNotSupported }
            if Self.hasZlibHeader(bytes) { throw Error.zlibNotSupported }
            if bytes.starts(with: [0x7b, 0x7d]) || bytes.starts(with: [0x7b, 0x22])
                || bytes.starts(with: [0x7b, 0x0a]) { throw Error.legacyJSONNotSupported }
            throw error
        }
    }

    public func read(_ bytes: [UInt8]) throws -> [BackupEntry] {
        let backup = try decode(bytes)
        return backup.manga.map(BackupEntry.manga)
            + backup.categories.map { .category(name: $0.name, order: $0.order) }
            + backup.sources.map { .source(id: $0.id, name: $0.name) }
            + [.coverage(backup.coverage)]
    }

    private static func hasZlibHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] & 0x0f == 8, bytes[0] >> 4 <= 7 else { return false }
        return (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0
    }
}
