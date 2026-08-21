import Foundation

#if canImport(SQLite3)

/// Serialized database access. All library mutations flow through this actor.
public actor LibraryStore {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        self.db = try SQLiteDatabase(path: path)
        try Migrations.apply(db)
    }

    public init(inMemory: Bool = true) throws {
        self.db = try SQLiteDatabase(path: inMemory ? ":memory:" : ":memory:")
        try Migrations.apply(db)
    }

    // MARK: - Manga

    public func libraryManga() throws -> [Manga] {
        try db.query("SELECT * FROM manga WHERE in_library = 1 ORDER BY title COLLATE NOCASE")
            .compactMap(Self.manga(from:))
    }

    public func manga(sourceId: Int64, url: String) throws -> Manga? {
        try db.query("SELECT * FROM manga WHERE source_id = ? AND url = ? LIMIT 1", [.int(sourceId), .text(url)])
            .first.flatMap(Self.manga(from:))
    }

    public func manga(id: Int64) throws -> Manga? {
        try db.query("SELECT * FROM manga WHERE id = ? LIMIT 1", [.int(id)])
            .first.flatMap(Self.manga(from:))
    }

    @discardableResult
    public func upsert(_ manga: Manga, inLibrary: Bool? = nil) throws -> Int64 {
        let alt = (try? String(data: JSONEncoder().encode(manga.altTitles), encoding: .utf8)) ?? "[]"
        let genres = (try? String(data: JSONEncoder().encode(manga.genres), encoding: .utf8)) ?? "[]"
        if let id = manga.id {
            try db.run("""
                UPDATE manga SET title=?, alt_titles=?, thumbnail_url=?, author=?, artist=?,
                    description=?, genres=?, status=?, in_library=?, update_strategy=?, date_updated=?
                WHERE id=?
                """, [.text(manga.title), .text(alt), manga.thumbnailURL.map { SQLiteBindable.text($0) } ?? .null,
                      manga.author.map { SQLiteBindable.text($0) } ?? .null, manga.artist.map { SQLiteBindable.text($0) } ?? .null,
                      manga.descriptionText.map { SQLiteBindable.text($0) } ?? .null, .text(genres), .int(Int64(manga.status.rawValue)),
                      .bool(inLibrary ?? manga.inLibrary), .text(manga.updateStrategy.rawValue),
                      .int(manga.dateUpdated), .int(id)])
            return id
        }
        return try db.insert("""
            INSERT OR IGNORE INTO manga
                (source_id, url, title, alt_titles, thumbnail_url, author, artist, description,
                 genres, status, in_library, date_added, update_strategy, initialized)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)
            """, [.int(manga.sourceId), .text(manga.url), .text(manga.title), .text(alt),
                  manga.thumbnailURL.map { SQLiteBindable.text($0) } ?? .null, manga.author.map { SQLiteBindable.text($0) } ?? .null,
                  manga.artist.map { SQLiteBindable.text($0) } ?? .null, manga.descriptionText.map { SQLiteBindable.text($0) } ?? .null,
                  .text(genres), .int(Int64(manga.status.rawValue)), .bool(inLibrary ?? manga.inLibrary),
                  .int(Int64(Date().timeIntervalSince1970)), .text(manga.updateStrategy.rawValue)])
    }

    public func setLibrary(_ inLibrary: Bool, mangaId: Int64) throws {
        try db.run("UPDATE manga SET in_library=? WHERE id=?", [.bool(inLibrary), .int(mangaId)])
        if !inLibrary {
            try db.run("DELETE FROM manga_category WHERE manga_id=?", [.int(mangaId)])
        }
    }

    // MARK: - Chapters

    public func chapters(mangaId: Int64) throws -> [Chapter] {
        try db.query("SELECT * FROM chapter WHERE manga_id=? ORDER BY source_order", [.int(mangaId)])
            .compactMap(Self.chapter(from:))
    }

    public func replaceChapters(mangaId: Int64, with chapters: [Chapter]) throws {
        try db.execute("BEGIN")
        do {
            // Preserve read/bookmark/progress state for URLs that persist.
            let existing = try db.query(
                "SELECT url, read, bookmark, last_page_read FROM chapter WHERE manga_id=?", [.int(mangaId)]
            )
            var state: [String: (Bool, Bool, Int)] = [:]
            for row in existing {
                if let url = row.string("url") {
                    state[url] = (row.bool("read"), row.bool("bookmark"), row.int("last_page_read") ?? 0)
                }
            }
            try db.run("DELETE FROM chapter WHERE manga_id=?", [.int(mangaId)])
            for (order, ch) in chapters.enumerated() {
                let prior = state[ch.url]
                _ = try db.insert("""
                    INSERT INTO chapter (manga_id, source_order, url, name, scanlator, number,
                                         date_upload, read, bookmark, last_page_read)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [.int(mangaId), .int(order), .text(ch.url), .text(ch.name),
                          ch.scanlator.map { SQLiteBindable.text($0) } ?? .null, .double(ch.number),
                          .int(ch.dateUpload), .bool(prior?.0 ?? ch.read),
                          .bool(prior?.1 ?? ch.bookmark), .int(prior?.2 ?? ch.lastPageRead)])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    public func markRead(_ read: Bool, chapterId: Int64) throws {
        try db.run("UPDATE chapter SET read=? WHERE id=?", [.bool(read), .int(chapterId)])
    }

    // MARK: - History

    public func recordHistory(mangaId: Int64, chapterId: Int64) throws {
        try db.run("""
            INSERT INTO history (manga_id, chapter_id, last_read, read_duration)
            VALUES (?,?,?,0)
            ON CONFLICT(manga_id, chapter_id) DO UPDATE SET last_read=excluded.last_read
            """, [.int(mangaId), .int(chapterId), .int(Int64(Date().timeIntervalSince1970))])
    }

    public func history() throws -> [(Manga, Chapter, Int64)] {
        let rows = try db.query("""
            SELECT m.*, c.url AS chapter_url, c.name AS chapter_name, c.id AS chapter_id, h.last_read
            FROM history h JOIN manga m ON m.id = h.manga_id JOIN chapter c ON c.id = h.chapter_id
            ORDER BY h.last_read DESC LIMIT 200
            """)
        return rows.compactMap { row in
            guard let m = Self.manga(from: row),
                  let chapterId = row.int("chapter_id"),
                  let chapterUrl = row.string("chapter_url"),
                  let chapterName = row.string("chapter_name"),
                  let lastRead = row.int64("last_read") else { return nil }
            return (m, Chapter(id: chapterId, mangaId: m.id ?? 0, url: chapterUrl, name: chapterName), lastRead)
        }
    }

    public func updateProgress(chapterId: Int64, page: Int) throws {
        try db.run("UPDATE chapter SET last_page_read=? WHERE id=?", [.int(page), .int(chapterId)])
    }

    // MARK: - Row mapping

    private static func manga(from row: SQLiteDatabase.Row) -> Manga? {
        guard let id = row.int64("id"),
              let sourceId = row.int64("source_id"),
              let url = row.string("url") else { return nil }
        let altData = row.string("alt_titles").flatMap { $0.data(using: .utf8) }
        let genreData = row.string("genres").flatMap { $0.data(using: .utf8) }
        return Manga(
            id: id,
            sourceId: sourceId,
            url: url,
            title: row.string("title") ?? "",
            altTitles: (altData.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [],
            thumbnailURL: row.string("thumbnail_url"),
            author: row.string("author"),
            artist: row.string("artist"),
            descriptionText: row.string("description"),
            genres: (genreData.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [],
            status: MangaStatus(rawValue: row.int("status") ?? 0) ?? .unknown,
            inLibrary: row.bool("in_library"),
            dateAdded: row.int64("date_added") ?? 0,
            dateUpdated: row.int64("date_updated") ?? 0,
            updateStrategy: UpdateStrategy(rawValue: row.string("update_strategy") ?? "") ?? .alwaysUpdate
        )
    }

    private static func chapter(from row: SQLiteDatabase.Row) -> Chapter? {
        guard let id = row.int64("id"), let url = row.string("url") else { return nil }
        return Chapter(
            id: id,
            mangaId: row.int64("manga_id") ?? 0,
            sourceOrder: row.int("source_order") ?? 0,
            url: url,
            name: row.string("name") ?? "",
            scanlator: row.string("scanlator"),
            number: row.double("number") ?? -1,
            dateUpload: row.int64("date_upload") ?? 0,
            read: row.bool("read"),
            bookmark: row.bool("bookmark"),
            lastPageRead: row.int("last_page_read") ?? 0
        )
    }
}

#endif