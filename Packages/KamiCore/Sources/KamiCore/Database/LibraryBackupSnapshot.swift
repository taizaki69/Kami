import Foundation
import MihonCompatKit

public enum LibraryBackupSnapshotError: Error, Equatable, Sendable, LocalizedError {
    case invalidStoredData
    case exportLimitExceeded
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidStoredData: return "Some saved library data could not be included faithfully in a backup."
        case .exportLimitExceeded: return "The saved library exceeds the backup limits."
        case .storageUnavailable: return "The library could not be read for backup."
        }
    }
}

#if canImport(SQLite3)

/// Called only inside LibraryStore's single read transaction. The UI queries
/// intentionally omit hidden chapters and limit history; an archive must not.
enum LibraryBackupSnapshotReader {
    typealias Document = LibraryBackupDocument
    typealias Failure = LibraryBackupSnapshotError

    static let foolSlideSourceID: Int64 = 6_351_052_922_295_965_587
    static let foolSlidePackage = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"
    private static let mangaDexSourceID: Int64 = 2_499_283_573_021_220_255

    static func read(
        _ db: SQLiteDatabase, exportID: UUID, exportedAt: Int64,
        policy: LibraryBackupPolicy,
        foolSlideBinding: () throws -> Document.ContentBinding
    ) throws -> Document {
        try Task.checkCancellation()
        guard exportedAt >= 0 else { throw LibraryBackupError.invalidSchema }
        try preflight(db, policy: policy)

        let categoryRows = try db.query("""
            SELECT id, CAST(name AS BLOB) AS name, sort_order, flags
            FROM category ORDER BY sort_order, id
            """)
        var categoryKeys: [Int64: String] = [:]
        var categories: [Document.Category] = []
        for (index, row) in categoryRows.enumerated() {
            try Task.checkCancellation()
            let key = "c\(index)"
            categoryKeys[try integer(row, "id")] = key
            categories.append(.init(key: key, name: try string(row, "name"),
                                    sortOrder: try integer(row, "sort_order"), flags: try integer(row, "flags")))
        }

        var memberships: [Int64: [String]] = [:]
        for row in try db.query("SELECT manga_id, category_id FROM manga_category ORDER BY manga_id, category_id") {
            try Task.checkCancellation()
            guard let key = categoryKeys[try integer(row, "category_id")] else { throw Failure.invalidStoredData }
            memberships[try integer(row, "manga_id"), default: []].append(key)
        }

        var chapters: [Int64: [Document.Chapter]] = [:]
        for row in try db.query("""
            SELECT manga_id, source_order, CAST(url AS BLOB) AS url, CAST(name AS BLOB) AS name,
                CAST(scanlator AS BLOB) AS scanlator, number, date_upload, date_fetch,
                read, bookmark, last_page_read, is_current
            FROM chapter ORDER BY manga_id, source_order, url COLLATE BINARY
            """) {
            try Task.checkCancellation()
            guard let number = row.double("number"), number.isFinite else { throw Failure.invalidStoredData }
            chapters[try integer(row, "manga_id"), default: []].append(.init(
                sourceOrder: try integer(row, "source_order"), url: try string(row, "url"),
                name: try string(row, "name"), scanlator: try optionalString(row, "scanlator"),
                number: number, dateUpload: try integer(row, "date_upload"), dateFetch: try integer(row, "date_fetch"),
                read: try boolean(row, "read"), bookmark: try boolean(row, "bookmark"),
                lastPageRead: try integer(row, "last_page_read"), isCurrent: try boolean(row, "is_current")
            ))
        }

        var history: [Int64: [Document.History]] = [:]
        for row in try db.query("""
            SELECT h.manga_id, CAST(c.url AS BLOB) AS url, h.last_read, h.read_duration
            FROM history h JOIN chapter c ON c.id=h.chapter_id
            ORDER BY h.manga_id, c.url COLLATE BINARY
            """) {
            try Task.checkCancellation()
            history[try integer(row, "manga_id"), default: []].append(.init(
                chapterURL: try string(row, "url"), lastRead: try integer(row, "last_read"),
                readDuration: try integer(row, "read_duration")
            ))
        }

        var baselines: [Int64: Document.DiscoveryBaseline] = [:]
        for row in try db.query("SELECT manga_id, established_at FROM chapter_discovery_baseline") {
            try Task.checkCancellation()
            baselines[try integer(row, "manga_id")] = .init(establishedAt: try integer(row, "established_at"))
        }
        var known: [Int64: [Document.KnownChapter]] = [:]
        for row in try db.query("""
            SELECT manga_id, CAST(url AS BLOB) AS url, first_seen, detected_at
            FROM known_chapter ORDER BY manga_id, url COLLATE BINARY
            """) {
            try Task.checkCancellation()
            let detected = row.isNull("detected_at") ? nil : try integer(row, "detected_at")
            known[try integer(row, "manga_id"), default: []].append(.init(
                url: try string(row, "url"), firstSeen: try integer(row, "first_seen"), detectedAt: detected
            ))
        }

        var manga: [Document.Manga] = []
        var sourceIDs: Set<Int64> = []
        for row in try db.query("""
            SELECT id, source_id, CAST(url AS BLOB) AS url, CAST(title AS BLOB) AS title,
                CAST(alt_titles AS BLOB) AS alt_titles, CAST(thumbnail_url AS BLOB) AS thumbnail_url,
                CAST(author AS BLOB) AS author, CAST(artist AS BLOB) AS artist,
                CAST(description AS BLOB) AS description, CAST(genres AS BLOB) AS genres,
                status, in_library, date_added, date_updated, last_fetched,
                CAST(update_strategy AS BLOB) AS update_strategy, initialized
            FROM manga ORDER BY source_id, url COLLATE BINARY
            """) {
            try Task.checkCancellation()
            let id = try integer(row, "id")
            let sourceID = try integer(row, "source_id")
            let statusValue = try integer(row, "status")
            guard let statusRaw = Int(exactly: statusValue), let status = MangaStatus(rawValue: statusRaw),
                  let strategy = UpdateStrategy(rawValue: try string(row, "update_strategy")) else {
                throw Failure.invalidStoredData
            }
            sourceIDs.insert(sourceID)
            manga.append(.init(
                sourceID: sourceID, url: try string(row, "url"), title: try string(row, "title"),
                altTitles: try stringArray(row, "alt_titles", maximumItems: policy.maximumAlternateTitles, policy: policy),
                thumbnailURL: try optionalString(row, "thumbnail_url"),
                author: try optionalString(row, "author"), artist: try optionalString(row, "artist"),
                descriptionText: try optionalString(row, "description"),
                genres: try stringArray(row, "genres", maximumItems: policy.maximumGenres, policy: policy),
                status: status, inLibrary: try boolean(row, "in_library"), dateAdded: try integer(row, "date_added"),
                dateUpdated: try integer(row, "date_updated"), lastFetched: try integer(row, "last_fetched"),
                updateStrategy: strategy, initialized: try boolean(row, "initialized"),
                categoryKeys: memberships[id, default: []], chapters: chapters[id, default: []],
                history: history[id, default: []], discoveryBaseline: baselines[id], knownChapters: known[id, default: []]
            ))
        }
        guard sourceIDs.count <= policy.maximumSources else { throw Failure.exportLimitExceeded }
        var sources: [Document.Source] = []
        for id in sourceIDs.sorted() {
            try Task.checkCancellation()
            if id == foolSlideSourceID {
                sources.append(.init(sourceID: id, name: "FoolSlide Customizable", contentBinding: try foolSlideBinding()))
            } else {
                sources.append(.init(sourceID: id, name: id == mangaDexSourceID ? "MangaDex" : ""))
            }
        }
        let document = Document(exportID: exportID, exportedAt: exportedAt,
                                sources: sources, categories: categories, manga: manga)
        try LibraryBackupCodec(policy: policy).validate(document)
        try Task.checkCancellation()
        return document
    }

    private struct TextColumn {
        let name: String
        let maximum: Int
        let nullable: Bool
        init(_ name: String, _ maximum: Int, nullable: Bool = false) {
            self.name = name; self.maximum = maximum; self.nullable = nullable
        }
        var validSQL: String {
            let test = "(typeof(\(name))='text' AND length(CAST(\(name) AS BLOB))<=\(maximum))"
            return nullable ? "(\(name) IS NULL OR \(test))" : test
        }
    }

    /// Count/type/byte checks happen before query() materializes stored text.
    /// Table/column names here are fixed source constants, never archive input.
    private static func preflight(_ db: SQLiteDatabase, policy: LibraryBackupPolicy) throws {
        let meta = policy.maximumMetadataBytes, url = policy.maximumURLBytes
        var storedTextBytes: Int64 = 0
        func check(_ table: String, maximum: Int, integers: [String],
                   optionalIntegers: [String] = [], texts: [TextColumn] = [], extras: [String] = []) throws {
            try Task.checkCancellation()
            guard let countRow = try db.query("SELECT COUNT(*) AS n FROM (SELECT 1 FROM \(table) LIMIT ?)",
                                               [.int(maximum + 1)]).first else { throw Failure.invalidStoredData }
            let count = try integer(countRow, "n")
            guard count >= 0, count <= Int64(maximum) else { throw Failure.exportLimitExceeded }
            try Task.checkCancellation()
            let checks = integers.map { "typeof(\($0))='integer'" }
                + optionalIntegers.map { "(\($0) IS NULL OR typeof(\($0))='integer')" }
                + texts.map(\.validSQL) + extras
            let valid = checks.isEmpty ? "1" : checks.joined(separator: " AND ")
            let byteSum = texts.isEmpty ? "0" : texts.map { "COALESCE(length(CAST(\($0.name) AS BLOB)),0)" }.joined(separator: "+")
            guard let row = try db.query("""
                SELECT COALESCE(SUM(\(byteSum)),0) AS bytes,
                    COALESCE(SUM(CASE WHEN \(valid) THEN 0 ELSE 1 END),0) AS invalid
                FROM \(table)
                """).first else { throw Failure.invalidStoredData }
            let bytes = try integer(row, "bytes")
            guard bytes >= 0,
                  bytes <= Int64(policy.maximumInputBytes) - storedTextBytes else { throw Failure.exportLimitExceeded }
            guard try integer(row, "invalid") == 0 else { throw Failure.invalidStoredData }
            storedTextBytes += bytes
        }
        try check("manga", maximum: policy.maximumManga,
                  integers: ["id", "source_id", "status", "in_library", "date_added", "date_updated", "last_fetched", "initialized"],
                  texts: [.init("url", url), .init("title", meta), .init("alt_titles", policy.maximumInputBytes),
                          .init("thumbnail_url", url, nullable: true), .init("author", meta, nullable: true),
                          .init("artist", meta, nullable: true), .init("description", policy.maximumDescriptionBytes, nullable: true),
                          .init("genres", policy.maximumInputBytes), .init("update_strategy", 32)],
                  extras: ["in_library IN (0,1)", "initialized IN (0,1)"])
        try check("category", maximum: policy.maximumCategories, integers: ["id", "sort_order", "flags"],
                  texts: [.init("name", policy.maximumLabelBytes)])
        try check("manga_category", maximum: policy.maximumMemberships, integers: ["manga_id", "category_id"])
        try check("chapter", maximum: policy.maximumChapters,
                  integers: ["id", "manga_id", "source_order", "date_upload", "date_fetch", "read", "bookmark", "last_page_read", "is_current"],
                  texts: [.init("url", url), .init("name", meta), .init("scanlator", meta, nullable: true)],
                  extras: ["typeof(number)='real'", "read IN (0,1)", "bookmark IN (0,1)", "is_current IN (0,1)"])
        // History repeats chapter URLs in the archive; count their bytes again.
        try check("history h LEFT JOIN chapter c ON c.id=h.chapter_id", maximum: policy.maximumHistory,
                  integers: ["h.manga_id", "h.chapter_id", "h.last_read", "h.read_duration"],
                  texts: [.init("c.url", url)])
        try check("chapter_discovery_baseline", maximum: policy.maximumManga, integers: ["manga_id", "established_at"])
        try check("known_chapter", maximum: policy.maximumKnownChapters, integers: ["manga_id", "first_seen"],
                  optionalIntegers: ["detected_at"], texts: [.init("url", url)])
        guard let sourceCount = try db.query("SELECT COUNT(DISTINCT source_id) AS n FROM manga").first?.int64("n"),
              sourceCount <= Int64(policy.maximumSources) else { throw Failure.exportLimitExceeded }
        let brokenRelations = [
            "SELECT 1 FROM manga_category mc LEFT JOIN manga m ON m.id=mc.manga_id LEFT JOIN category c ON c.id=mc.category_id WHERE m.id IS NULL OR m.in_library!=1 OR c.id IS NULL LIMIT 1",
            "SELECT 1 FROM chapter c LEFT JOIN manga m ON m.id=c.manga_id WHERE m.id IS NULL LIMIT 1",
            "SELECT 1 FROM history h LEFT JOIN manga m ON m.id=h.manga_id LEFT JOIN chapter c ON c.id=h.chapter_id WHERE m.id IS NULL OR c.id IS NULL OR c.manga_id!=h.manga_id LIMIT 1",
            "SELECT 1 FROM known_chapter k LEFT JOIN manga m ON m.id=k.manga_id WHERE m.id IS NULL LIMIT 1",
            "SELECT 1 FROM chapter_discovery_baseline b LEFT JOIN manga m ON m.id=b.manga_id WHERE m.id IS NULL LIMIT 1",
        ]
        for sql in brokenRelations {
            try Task.checkCancellation()
            guard try db.query(sql).isEmpty else { throw Failure.invalidStoredData }
        }
        guard try db.query("""
            SELECT 1 FROM chapter GROUP BY manga_id HAVING COUNT(*)>? LIMIT 1
            """, [.int(policy.maximumChaptersPerManga)]).isEmpty else { throw Failure.exportLimitExceeded }
    }

    /// The existing settings mapper reads C strings. Before reusing it for a
    /// descriptive content binding, bound every column its queries materialize.
    /// SQLite's INTEGER affinity alone does not prohibit stored TEXT or BLOBs.
    static func hasBoundedFoolSlideConfiguration(_ db: SQLiteDatabase) throws -> Bool {
        let fields = ["package_name", "version_name", "apk_path", "repo_url", "apk_sha256", "signature_scheme",
                      "current_signers", "signer_history", "trust_source", "source_ids"]
        let textTests = fields.map { "(\($0) IS NULL OR (typeof(\($0))='text' AND length(CAST(\($0) AS BLOB))<=16384))" }
        let integerTests = ["version_code", "installed_at", "enabled"].map { "typeof(\($0))='integer'" }
        let tests = (textTests + integerTests + ["enabled IN (0,1)", "installed_at>=0"]).joined(separator: " AND ")
        let columns = fields.map { "CAST(\($0) AS BLOB) AS \($0)" }.joined(separator: ",")
        guard let row = try db.query("SELECT \(columns) FROM installed_extension WHERE package_name=? AND \(tests) LIMIT 1",
                                     [.text(foolSlidePackage)]).first else { return false }
        for field in fields {
            if row.isNull(field) { continue }
            guard let bytes = row.bytes(field), !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else { return false }
        }
        guard let config = try db.query("""
            SELECT CAST(identity_fingerprint AS BLOB) AS fingerprint, CAST(user_values AS BLOB) AS payload
            FROM installed_extension_preferences WHERE package_name=?
                AND typeof(identity_fingerprint)='text' AND length(CAST(identity_fingerprint AS BLOB))=64
                AND typeof(schema_revision)='integer' AND schema_revision>0
                AND typeof(revision)='integer' AND revision>0
                AND typeof(user_values)='text' AND length(CAST(user_values AS BLOB))<=16384
            LIMIT 1
            """, [.text(foolSlidePackage)]).first else { return false }
        for field in ["fingerprint", "payload"] {
            guard let bytes = config.bytes(field), !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else { return false }
        }
        return true
    }

    private static func integer(_ row: SQLiteDatabase.Row, _ field: String) throws -> Int64 {
        guard let value = row.int64(field) else { throw Failure.invalidStoredData }
        return value
    }
    private static func boolean(_ row: SQLiteDatabase.Row, _ field: String) throws -> Bool {
        let value = try integer(row, field)
        guard value == 0 || value == 1 else { throw Failure.invalidStoredData }
        return value == 1
    }
    private static func string(_ row: SQLiteDatabase.Row, _ field: String) throws -> String {
        guard let bytes = row.bytes(field), !bytes.contains(0),
              let value = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidStoredData }
        return value
    }
    private static func optionalString(_ row: SQLiteDatabase.Row, _ field: String) throws -> String? {
        row.isNull(field) ? nil : try string(row, field)
    }
    private static func stringArray(
        _ row: SQLiteDatabase.Row, _ field: String, maximumItems: Int, policy: LibraryBackupPolicy
    ) throws -> [String] {
        let text = try string(row, field)
        let data = Data(text.utf8)
        // A short byte buffer can encode millions of empty strings. Bound the
        // number of values before Foundation allocates that array as well.
        let arrayPolicy = try LibraryBackupPolicy(
            maximumInputBytes: policy.maximumInputBytes, maximumDepth: min(2, policy.maximumDepth),
            maximumJSONValues: min(maximumItems + 1, policy.maximumJSONValues),
            maximumJSONStringBytes: min(policy.maximumJSONStringBytes, policy.maximumTotalStringBytes),
            maximumJSONObjectKeys: policy.maximumJSONObjectKeys,
            maximumJSONArrayElements: min(maximumItems, policy.maximumJSONArrayElements)
        )
        var preflight = try LibraryBackupJSONPreflight(data: data, policy: arrayPolicy)
        try preflight.run()
        do {
            let result = try JSONDecoder().decode([String].self, from: data)
            guard result.count <= maximumItems else { throw Failure.exportLimitExceeded }
            return result
        }
        catch { throw Failure.invalidStoredData }
    }
}
#endif
