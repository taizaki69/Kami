import Foundation
import MihonCompatKit

#if canImport(SQLite3)

/// All entry points are called inside the owning store's transaction. Nothing
/// here consults a source registry, grants a file lease, or rotates an epoch.
enum ReadingStateReader {
    private typealias Failure = ReadingStateError
    static let maximumChapters = 20_000
    private static let maximumURLBytes = 4_096
    private static let maximumMetadataBytes = 8_192
    private static let maximumDescriptionBytes = 262_144
    private static let maximumArrayItems = 256
    private static let maximumArrayJSONBytes = 16 * 1_024 * 1_024
    private static let maximumStoredTextBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumStringBytes = 32 * 1_024 * 1_024

    static func validateInputURL(_ url: String) throws {
        guard url.utf8.count <= maximumURLBytes, validIdentity(url) else { throw Failure.invalidInput }
    }

    static func epoch(_ db: SQLiteDatabase) throws -> LibraryDataEpoch {
        try Task.checkCancellation()
        // Only metadata is read until the singleton, type and byte count are
        // proven. Missing/corrupt state must never seed a replacement epoch.
        guard let row = try db.query("""
            SELECT COUNT(*) AS n,
                COALESCE(SUM(CASE WHEN typeof(singleton)='integer' AND singleton=1
                    AND typeof(epoch)='blob' AND length(epoch)=16 THEN 0 ELSE 1 END),0) AS invalid
            FROM (SELECT singleton,epoch FROM library_data_state LIMIT 2)
            """).first,
              row.int64("n") == 1, row.int64("invalid") == 0,
              let bytes = try db.query("SELECT epoch FROM library_data_state WHERE singleton=1 LIMIT 1").first?.bytes("epoch"),
              bytes.count == 16 else { throw Failure.invalidStoredData }
        return LibraryDataEpoch(bytes: Data(bytes))
    }

    static func mangaID(_ db: SQLiteDatabase, sourceID: Int64, url: String) throws -> Int64? {
        try Task.checkCancellation()
        let rows = try db.query("""
            SELECT CASE WHEN typeof(id)='integer' THEN id ELSE NULL END AS id
            FROM manga WHERE source_id=? AND CAST(url AS BLOB)=? LIMIT 2
            """, [.int(sourceID), .blob(Array(url.utf8))])
        guard rows.count <= 1 else { throw Failure.invalidStoredData }
        guard let row = rows.first else { return nil }
        return try integer(row, "id")
    }

    static func snapshot(
        _ db: SQLiteDatabase, ownerID: UUID, epoch: LibraryDataEpoch,
        mangaID: Int64, requestedChapterID: Int64?
    ) throws -> MangaReadingSnapshot {
        try Task.checkCancellation()
        var storedBytes: Int64 = 0
        try preflightManga(db, mangaID: mangaID, storedBytes: &storedBytes)
        if let requestedChapterID {
            guard let row = try db.query("""
                SELECT CASE WHEN typeof(manga_id)='integer' THEN manga_id ELSE NULL END AS manga_id
                FROM chapter WHERE id=? LIMIT 1
                """, [.int(requestedChapterID)]).first else { throw Failure.chapterNotFound }
            guard try integer(row, "manga_id") == mangaID else { throw Failure.identityChanged }
        }
        let selection = """
            c.manga_id=? AND (c.is_current=1 OR EXISTS (
                SELECT 1 FROM download_job j WHERE j.chapter_id=c.id AND j.state=2
            ) OR (? IS NOT NULL AND c.id=?))
            """
        let request = requestedChapterID.map(SQLiteBindable.int) ?? .null
        let values: [SQLiteBindable] = [.int(mangaID), request, request]
        try preflightChapters(db, selection: selection, values: values,
                              maximum: maximumChapters, storedBytes: &storedBytes)
        // A corrupt completed job must not invent a neighbour under another
        // manga. This is still only membership, not evidence of valid files.
        guard try db.query("""
            SELECT 1 FROM chapter c JOIN download_job j ON j.chapter_id=c.id
            WHERE \(selection) AND j.state=2 AND (
                typeof(j.manga_id)!='integer' OR j.manga_id!=c.manga_id OR
                typeof(j.source_id)!='integer' OR j.source_id!=(SELECT source_id FROM manga WHERE id=c.manga_id)
            ) LIMIT 1
            """, values).isEmpty else { throw Failure.invalidStoredData }

        var budget = StringBudget()
        guard let mangaRow = try db.query(mangaColumns + " FROM manga WHERE id=? LIMIT 1", [.int(mangaID)]).first else {
            throw Failure.mangaNotFound
        }
        let manga = try decodeManga(mangaRow, budget: &budget)
        var current: [Chapter] = [], downloaded: [Chapter] = []
        var requested: Chapter?
        var targets: [Int64: ChapterWriteTarget] = [:]
        for row in try db.query(chapterColumns + """
            ,CASE WHEN EXISTS (SELECT 1 FROM download_job j WHERE j.chapter_id=c.id AND j.state=2)
                THEN 1 ELSE 0 END AS downloaded
            FROM chapter c WHERE \(selection) ORDER BY c.source_order,c.id
            """, values) {
            try Task.checkCancellation()
            let chapter = try decodeChapter(row, budget: &budget)
            guard let chapterID = chapter.id, chapter.mangaId == mangaID else { throw Failure.invalidStoredData }
            if try boolean(row, "is_current") { current.append(chapter) }
            if try boolean(row, "downloaded") { downloaded.append(chapter) }
            if chapterID == requestedChapterID { requested = chapter }
            guard targets[chapterID] == nil else { throw Failure.invalidStoredData }
            targets[chapterID] = ChapterWriteTarget(ownerID: ownerID, epoch: epoch, mangaID: mangaID,
                                                    chapterID: chapterID, sourceID: manga.sourceId,
                                                    mangaURL: manga.url, chapterURL: chapter.url)
        }
        if requestedChapterID != nil, requested == nil { throw Failure.chapterNotFound }
        return MangaReadingSnapshot(manga: manga, epoch: epoch,
                                    mutationContext: .init(ownerID: ownerID, epoch: epoch), currentChapters: current,
                                    downloadedChapters: downloaded, requestedChapter: requested, targets: targets)
    }

    static func validate(_ db: SQLiteDatabase, ownerID: UUID, target: ChapterWriteTarget) throws -> Chapter {
        try Task.checkCancellation()
        guard target.ownerID == ownerID else { throw Failure.foreignTarget }
        guard try epoch(db) == target.epoch else { throw Failure.staleEpoch }
        var storedBytes: Int64 = 0
        // Identity-only parent checks avoid materializing unrelated metadata
        // during a progress save, while still rejecting TEXT/BLOB scalar tricks.
        let parentCount = try preflight(db, from: "manga", selection: "id=?", values: [.int(target.mangaID)],
                                        maximum: 1, integers: ["id", "source_id"],
                                        texts: [.init("url", maximumURLBytes)], storedBytes: &storedBytes)
        guard parentCount == 1 else { throw Failure.mangaNotFound }
        guard let parent = try db.query("SELECT source_id,CAST(url AS BLOB) AS url FROM manga WHERE id=? LIMIT 1",
                                        [.int(target.mangaID)]).first else { throw Failure.mangaNotFound }
        var budget = StringBudget()
        let sourceID = try integer(parent, "source_id")
        let mangaURL = try budget.string(parent, "url", identity: true)
        guard sourceID == target.sourceID, Data(mangaURL.utf8) == Data(target.mangaURL.utf8) else {
            throw Failure.identityChanged
        }
        let count = try preflightChapters(db, selection: "c.id=?", values: [.int(target.chapterID)],
                                         maximum: 1, storedBytes: &storedBytes)
        guard count == 1 else { throw Failure.chapterNotFound }
        guard let row = try db.query(chapterColumns + " FROM chapter c WHERE c.id=? LIMIT 1",
                                     [.int(target.chapterID)]).first else { throw Failure.chapterNotFound }
        guard try integer(row, "manga_id") == target.mangaID else { throw Failure.identityChanged }
        let chapter = try decodeChapter(row, budget: &budget)
        guard target.matches(mangaURL: mangaURL, chapterURL: chapter.url) else { throw Failure.identityChanged }
        return chapter
    }

    static func history(_ db: SQLiteDatabase, target: ChapterWriteTarget) throws -> (lastRead: Int64, duration: Int64)? {
        try Task.checkCancellation()
        guard let count = try db.query("SELECT COUNT(*) AS n FROM (SELECT 1 FROM history WHERE chapter_id=? LIMIT 2)",
                                       [.int(target.chapterID)]).first?.int64("n"), count <= 1 else {
            throw Failure.invalidStoredData
        }
        var storedBytes: Int64 = 0
        _ = try preflight(db, from: "history", selection: "chapter_id=?", values: [.int(target.chapterID)],
                          maximum: 1, integers: ["manga_id", "chapter_id", "last_read", "read_duration"],
                          extras: ["last_read>=0", "read_duration>=0"], storedBytes: &storedBytes)
        guard let row = try db.query("SELECT manga_id,chapter_id,last_read,read_duration FROM history WHERE chapter_id=? LIMIT 1",
                                     [.int(target.chapterID)]).first else { return nil }
        guard try integer(row, "manga_id") == target.mangaID else { throw Failure.invalidStoredData }
        return (try integer(row, "last_read"), try integer(row, "read_duration"))
    }

    private static let mangaColumns = """
        SELECT id,source_id,CAST(url AS BLOB) AS url,CAST(title AS BLOB) AS title,
            CAST(alt_titles AS BLOB) AS alt_titles,CAST(thumbnail_url AS BLOB) AS thumbnail_url,
            CAST(author AS BLOB) AS author,CAST(artist AS BLOB) AS artist,
            CAST(description AS BLOB) AS description,CAST(genres AS BLOB) AS genres,
            status,in_library,date_added,date_updated,CAST(update_strategy AS BLOB) AS update_strategy
        """
    private static let chapterColumns = """
        SELECT c.id,c.manga_id,c.source_order,CAST(c.url AS BLOB) AS url,CAST(c.name AS BLOB) AS name,
            CAST(c.scanlator AS BLOB) AS scanlator,c.number,c.date_upload,c.read,c.bookmark,c.last_page_read,c.is_current
        """

    private static func preflightManga(_ db: SQLiteDatabase, mangaID: Int64, storedBytes: inout Int64) throws {
        let count = try preflight(db, from: "manga", selection: "id=?", values: [.int(mangaID)], maximum: 1,
                                  integers: ["id", "source_id", "status", "in_library", "date_added", "date_updated", "last_fetched", "initialized"],
                                  texts: [.init("url", maximumURLBytes), .init("title", maximumMetadataBytes),
                                          .init("alt_titles", maximumArrayJSONBytes), .init("genres", maximumArrayJSONBytes),
                                          .init("thumbnail_url", maximumURLBytes, nullable: true),
                                          .init("author", maximumMetadataBytes, nullable: true),
                                          .init("artist", maximumMetadataBytes, nullable: true),
                                          .init("description", maximumDescriptionBytes, nullable: true),
                                          .init("update_strategy", maximumMetadataBytes)],
                                  extras: ["status BETWEEN 0 AND 6", "in_library IN (0,1)", "initialized IN (0,1)",
                                           "date_added>=0", "date_updated>=0", "last_fetched>=0"], storedBytes: &storedBytes)
        guard count == 1 else { throw Failure.mangaNotFound }
    }

    @discardableResult
    private static func preflightChapters(
        _ db: SQLiteDatabase, selection: String, values: [SQLiteBindable], maximum: Int, storedBytes: inout Int64
    ) throws -> Int64 {
        try preflight(db, from: "chapter c", selection: selection, values: values, maximum: maximum,
                       integers: ["c.id", "c.manga_id", "c.source_order", "c.date_upload", "c.date_fetch", "c.read", "c.bookmark", "c.last_page_read", "c.is_current"],
                       texts: [.init("c.url", maximumURLBytes), .init("c.name", maximumMetadataBytes),
                               .init("c.scanlator", maximumMetadataBytes, nullable: true)],
                       extras: ["typeof(c.number)='real'", "c.read IN (0,1)", "c.bookmark IN (0,1)",
                                "c.is_current IN (0,1)", "c.date_upload>=0", "c.date_fetch>=0", "c.last_page_read>=0"],
                       storedBytes: &storedBytes)
    }

    private struct TextColumn {
        let name: String
        let maximum: Int
        let nullable: Bool
        init(_ name: String, _ maximum: Int, nullable: Bool = false) {
            self.name = name; self.maximum = maximum; self.nullable = nullable
        }
        var typeSQL: String {
            let test = "typeof(\(name))='text'"
            return nullable ? "(\(name) IS NULL OR \(test))" : test
        }
        var sizeSQL: String { "COALESCE(length(CAST(\(name) AS BLOB)),0)<=\(maximum)" }
    }

    /// Fixed internal SQL identifiers only. Counts and scalar types/lengths are
    /// checked before query() can allocate any untrusted stored field value.
    @discardableResult
    private static func preflight(
        _ db: SQLiteDatabase, from: String, selection: String, values: [SQLiteBindable], maximum: Int,
        integers: [String], texts: [TextColumn] = [], extras: [String] = [], storedBytes: inout Int64
    ) throws -> Int64 {
        try Task.checkCancellation()
        guard let count = try db.query("SELECT COUNT(*) AS n FROM (SELECT 1 FROM \(from) WHERE \(selection) LIMIT ?)",
                                       values + [.int(maximum + 1)]).first?.int64("n") else { throw Failure.invalidStoredData }
        guard count <= Int64(maximum) else { throw Failure.limitExceeded }
        let types = (integers.map { "typeof(\($0))='integer'" } + texts.map(\.typeSQL) + extras).joined(separator: " AND ")
        let sizes = texts.isEmpty ? "1" : texts.map(\.sizeSQL).joined(separator: " AND ")
        let bytes = texts.isEmpty ? "0" : texts.map { "COALESCE(length(CAST(\($0.name) AS BLOB)),0)" }.joined(separator: "+")
        try Task.checkCancellation()
        guard let row = try db.query("""
            SELECT COALESCE(SUM(CASE WHEN \(types) THEN 0 ELSE 1 END),0) AS invalid,
                COALESCE(SUM(CASE WHEN \(sizes) THEN 0 ELSE 1 END),0) AS oversized,
                COALESCE(SUM(\(bytes)),0) AS bytes FROM \(from) WHERE \(selection)
            """, values).first,
              let invalid = row.int64("invalid"), let oversized = row.int64("oversized"),
              let byteCount = row.int64("bytes") else { throw Failure.invalidStoredData }
        guard invalid == 0 else { throw Failure.invalidStoredData }
        guard oversized == 0, byteCount >= 0, byteCount <= maximumStoredTextBytes - storedBytes else {
            throw Failure.limitExceeded
        }
        storedBytes += byteCount
        return count
    }

    private static func decodeManga(_ row: SQLiteDatabase.Row, budget: inout StringBudget) throws -> Manga {
        guard let statusRaw = Int(exactly: try integer(row, "status")), let status = MangaStatus(rawValue: statusRaw),
              let strategy = UpdateStrategy(rawValue: try budget.string(row, "update_strategy")) else {
            throw Failure.invalidStoredData
        }
        return Manga(id: try integer(row, "id"), sourceId: try integer(row, "source_id"),
                     url: try budget.string(row, "url", identity: true), title: try budget.string(row, "title"),
                     altTitles: try budget.array(row, "alt_titles"), thumbnailURL: try budget.optionalString(row, "thumbnail_url"),
                     author: try budget.optionalString(row, "author"), artist: try budget.optionalString(row, "artist"),
                     descriptionText: try budget.optionalString(row, "description"), genres: try budget.array(row, "genres"),
                     status: status, inLibrary: try boolean(row, "in_library"), dateAdded: try integer(row, "date_added"),
                     dateUpdated: try integer(row, "date_updated"), updateStrategy: strategy)
    }

    private static func decodeChapter(_ row: SQLiteDatabase.Row, budget: inout StringBudget) throws -> Chapter {
        guard let number = row.double("number"), number.isFinite,
              let order = Int(exactly: try integer(row, "source_order")),
              let page = Int(exactly: try integer(row, "last_page_read")) else { throw Failure.invalidStoredData }
        return Chapter(id: try integer(row, "id"), mangaId: try integer(row, "manga_id"), sourceOrder: order,
                       url: try budget.string(row, "url", identity: true), name: try budget.string(row, "name"),
                       scanlator: try budget.optionalString(row, "scanlator"), number: number,
                       dateUpload: try integer(row, "date_upload"), read: try boolean(row, "read"),
                       bookmark: try boolean(row, "bookmark"), lastPageRead: page)
    }

    private static func integer(_ row: SQLiteDatabase.Row, _ field: String) throws -> Int64 {
        guard let result = row.int64(field) else { throw Failure.invalidStoredData }
        return result
    }

    private static func boolean(_ row: SQLiteDatabase.Row, _ field: String) throws -> Bool {
        let value = try integer(row, field)
        guard value == 0 || value == 1 else { throw Failure.invalidStoredData }
        return value == 1
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private struct StringBudget {
        private var bytes = 0
        private mutating func charge(_ count: Int) throws {
            guard count <= maximumStringBytes - bytes else { throw Failure.limitExceeded }
            bytes += count
        }
        mutating func string(_ row: SQLiteDatabase.Row, _ field: String, identity: Bool = false) throws -> String {
            guard let data = row.bytes(field) else { throw Failure.invalidStoredData }
            try charge(data.count)
            guard !data.contains(0), let result = String(bytes: data, encoding: .utf8),
                  !identity || validIdentity(result) else {
                throw Failure.invalidStoredData
            }
            return result
        }
        mutating func optionalString(_ row: SQLiteDatabase.Row, _ field: String) throws -> String? {
            row.isNull(field) ? nil : try string(row, field)
        }
        mutating func array(_ row: SQLiteDatabase.Row, _ field: String) throws -> [String] {
            guard let bytes = row.bytes(field), String(bytes: bytes, encoding: .utf8) != nil else {
                throw Failure.invalidStoredData
            }
            do {
                let policy = try LibraryBackupPolicy(maximumInputBytes: maximumArrayJSONBytes, maximumDepth: 2,
                    maximumJSONValues: maximumArrayItems + 1, maximumJSONStringBytes: maximumStringBytes,
                    maximumJSONArrayElements: maximumArrayItems)
                let data = Data(bytes)
                var preflight = try LibraryBackupJSONPreflight(data: data, policy: policy)
                try preflight.run()
                let result = try JSONDecoder().decode([String].self, from: data)
                for string in result {
                    try Task.checkCancellation()
                    guard !string.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.invalidStoredData }
                    guard string.utf8.count <= maximumMetadataBytes else { throw Failure.limitExceeded }
                    try charge(string.utf8.count)
                }
                return result
            } catch is CancellationError { throw CancellationError() }
            catch let error as ReadingStateError { throw error }
            catch LibraryBackupError.limitExceeded(_) { throw Failure.limitExceeded }
            catch { throw Failure.invalidStoredData }
        }
    }
}

#endif
