import Foundation

/// Reader for Mihon/Tachiyomi `.tachibk` backups.
///
/// Format (verified against Mihon `data/backup/models/Backup.kt` +
/// `BackupDecoder.kt`): a protobuf `Backup` message, either zstd-compressed
/// (current Mihon, magic `28 B5 2F FD`) or zlib-deflated (legacy Tachiyomi,
/// first byte `0x78`). This reader fully supports the legacy stream and the
/// protobuf decoding of both; zstd payload decompression returns
/// `.zstdNotSupported` until a decompressor lands (see docs/BACKUP_COMPATIBILITY.md).
public struct TachibkReader {
    public enum BackupEntry {
        case manga(BackupManga)
        case category(name: String, order: Int)
        case source(id: Int64, name: String)
        case preference(key: String, value: String)
        case extensionStore(name: String)
        case unknown(field: Int)
    }

    public struct BackupManga {
        public var url: String
        public var title: String
        public var artist: String?
        public var author: String?
        public var descriptionText: String?
        public var genre: [String]
        public var status: Int
        public var sourceId: Int64
        public var favorite: Bool
        public var chapterCount: Int
        public var categories: [Int]
        public var chapters: [BackupChapter]
        public var history: [BackupHistory]
    }

    public struct BackupChapter {
        public var url: String
        public var name: String
        public var scanlator: String?
        public var read: Bool
        public var bookmark: Bool
        public var lastPageRead: Int
        public var dateFetch: Int64
        public var dateUpload: Int64
        public var chapterNumber: Float
        public var sourceOrder: Int
    }

    public struct BackupHistory {
        public var url: String
        public var lastRead: Int64
        public var readDuration: Int64
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case zstdNotSupported
        case unknownCompression(firstByte: UInt8)
        case notProtobuf

        public var description: String {
            switch self {
            case .zstdNotSupported:
                return "backup uses zstd compression; Kami's zstd decoder is not wired in yet (see docs/BACKUP_COMPATIBILITY.md)"
            case let .unknownCompression(b):
                return "unrecognized backup compression (first byte 0x\(String(b, radix: 16)))"
            case .notProtobuf:
                return "decompressed payload is not a protobuf message"
            }
        }
    }

    /// Field numbers verified against Mihon `data/backup/models/Backup.kt`
    /// (fetched 2026-08-21): 1 manga, 2 categories, 101 sources,
    /// 104 preferences, 105 sourcePreferences, 106 extensionStores.
    private enum Fields {
        static let backupManga = 1
        static let backupCategories = 2
        static let backupSources = 101
        static let backupPreferences = 104
        static let backupSourcePreferences = 105
        static let backupExtensionStores = 106
    }

    public init() {}

    /// Decodes a full backup into typed entries.
    public func read(_ bytes: [UInt8]) throws -> [BackupEntry] {
        let payload: [UInt8]
        if bytes.count >= 4, bytes[0] == 0x28, bytes[1] == 0xB5, bytes[2] == 0x2F, bytes[3] == 0xFD {
            throw Error.zstdNotSupported
        } else if bytes.first == 0x78 {
            payload = try Zlib.decompress(bytes)
        } else if bytes.first == 0x0A {
            // Uncompressed protobuf (field 1, wire type 2).
            payload = bytes
        } else {
            throw Error.unknownCompression(firstByte: bytes.first ?? 0)
        }

        let root = try ProtoMessage(payload)
        var entries: [BackupEntry] = []

        for mangaMsg in root.messages(Fields.backupManga) {
            entries.append(.manga(Self.manga(from: mangaMsg)))
        }
        for category in root.messages(Fields.backupCategories) {
            entries.append(.category(
                name: category.string(1) ?? "",
                order: category.int(2) ?? 0
            ))
        }
        for source in root.messages(Fields.backupSources) {
            entries.append(.source(
                id: source.int64(2) ?? 0,
                name: source.string(1) ?? ""
            ))
        }
        for pref in root.messages(Fields.backupPreferences) {
            entries.append(.preference(
                key: pref.string(1) ?? "",
                value: pref.string(2) ?? ""
            ))
        }
        for store in root.messages(Fields.backupExtensionStores) {
            entries.append(.extensionStore(name: store.string(1) ?? ""))
        }
        return entries
    }

    /// BackupManga @ProtoNumber fields (Mihon BackupManga.kt): 1 source,
    /// 2 url, 3 title, 4 artist, 5 author, 6 description, 7 genre, 8 status,
    /// 9 thumbnailUrl, 13 dateAdded, 16 chapters, 17 categories (repeated
    /// Long), 100 favorite, 104 history.
    private static func manga(from m: ProtoMessage) -> BackupManga {
        let chapters = m.messages(16).map { c in
            // BackupChapter: 1 url, 2 name, 3 scanlator, 4 read, 5 bookmark,
            // 6 lastPageRead, 7 dateFetch, 8 dateUpload, 9 chapterNumber
            // (Float, fixed32), 10 sourceOrder.
            BackupChapter(
                url: c.string(1) ?? "",
                name: c.string(2) ?? "",
                scanlator: c.string(3),
                read: (c.int(4) ?? 0) != 0,
                bookmark: (c.int(5) ?? 0) != 0,
                lastPageRead: c.int(6) ?? 0,
                dateFetch: c.int64(7) ?? 0,
                dateUpload: c.int64(8) ?? 0,
                chapterNumber: c.float(9) ?? 0,
                sourceOrder: c.int(10) ?? 0
            )
        }
        let history = m.messages(104).map { h in
            BackupHistory(url: h.string(1) ?? "", lastRead: h.int64(2) ?? 0, readDuration: h.int64(3) ?? 0)
        }
        return BackupManga(
            url: m.string(2) ?? "",
            title: m.string(3) ?? "",
            artist: m.string(4),
            author: m.string(5),
            descriptionText: m.string(6),
            genre: m.strings(7),
            status: m.int(8) ?? 0,
            sourceId: m.int64(1) ?? 0,
            favorite: (m.int(100) ?? 0) != 0,
            chapterCount: chapters.count,
            categories: m.ints(17),
            chapters: chapters,
            history: history
        )
    }
}
