import Foundation

#if canImport(SQLite3)
/// Called only in the store's validated write transaction. Chapter URL bytes
/// bind existing destination state. Matching never changes a stored identity.
enum SourceMigrationPersistence {
    static func write(_ db: SQLiteDatabase, preview: SourceMigrationPreview,
                      matches: [SourceMigrationMatch], copyCategories: Bool) throws -> Int64 {
        let manga = preview.destination.manga
        let now = Int64(Date().timeIntervalSince1970)
        let id: Int64
        if let existing = try ReadingStateReader.mangaID(db, sourceID: manga.sourceID, url: manga.url) {
            id = existing
            guard let row = try db.query("SELECT in_library,library_revision FROM manga WHERE id=?", [.int(id)]).first,
                  let revision = row.int64("library_revision"), row.int64("in_library") == 1 || revision < Int64.max else {
                throw SourceMigrationError.storageUnavailable
            }
            try db.run("UPDATE manga SET in_library=1 WHERE id=? AND in_library=0", [.int(id)])
        } else {
            id = try db.insert("""
                INSERT INTO manga(source_id,url,title,alt_titles,thumbnail_url,author,artist,description,
                                  genres,status,in_library,date_added,update_strategy,initialized)
                VALUES (?,?,?,?,?,?,?,?,?,?,1,?,?,1)
                """, [.int(manga.sourceID), .text(manga.url), .text(manga.title), .text(try json(manga.altTitles)),
                      text(manga.thumbnailURL), text(manga.author), text(manga.artist), text(manga.descriptionText),
                      .text(try json(manga.genres)), .int(manga.status.rawValue), .int(now), .text(manga.updateStrategy.rawValue)])
        }
        var transferred: [Data: LibraryBackupDocument.Chapter] = [:]
        for match in matches {
            transferred[Data(match.destination.url.utf8)] = match.original
        }
        for chapter in manga.chapters {
            try Task.checkCancellation()
            let flags = transferred[Data(chapter.url.utf8)]
            let existing = try db.query("SELECT id FROM chapter WHERE manga_id=? AND CAST(url AS BLOB)=? LIMIT 2",
                                       [.int(id), .blob(Array(chapter.url.utf8))])
            guard existing.count <= 1 else { throw SourceMigrationError.storageUnavailable }
            if let row = existing.first {
                guard let chapterID = row.int64("id") else { throw SourceMigrationError.storageUnavailable }
                // Preserve page offsets, metadata, currentness and history.
                // An already-downloaded destination is not invalidated.
                if let flags {
                    try db.run("UPDATE chapter SET read=MAX(read,?),bookmark=MAX(bookmark,?) WHERE id=?",
                               [.bool(flags.read), .bool(flags.bookmark), .int(chapterID)])
                }
            } else {
                _ = try db.insert("""
                    INSERT INTO chapter(manga_id,source_order,url,name,scanlator,number,date_upload,
                                        read,bookmark,last_page_read,is_current)
                    VALUES (?,?,?,?,?,?,?,?,?,0,1)
                    """, [.int(id), .int(chapter.sourceOrder), .text(chapter.url), .text(chapter.name), text(chapter.scanlator),
                          .double(chapter.number), .int(chapter.dateUpload), .bool(flags?.read ?? false), .bool(flags?.bookmark ?? false)])
            }
        }
        if copyCategories {
            try db.run("""
                INSERT OR IGNORE INTO manga_category(manga_id,category_id)
                SELECT ?,category_id FROM manga_category WHERE manga_id=?
                """, [.int(id), .int(preview.originID)])
        }
        // Establish only missing baseline entries without announcing imported
        // chapters as new updates or overwriting prior discovery timestamps.
        try db.run("INSERT OR IGNORE INTO chapter_discovery_baseline(manga_id,established_at) VALUES (?,?)", [.int(id), .int(now)])
        try db.run("""
            INSERT OR IGNORE INTO known_chapter(manga_id,url,first_seen,detected_at)
            SELECT manga_id,url,?,NULL FROM chapter WHERE manga_id=?
            """, [.int(now), .int(id)])
        return id
    }

    private static func text(_ value: String?) -> SQLiteBindable { value.map(SQLiteBindable.text) ?? .null }
    private static func json(_ values: [String]) throws -> String { String(decoding: try JSONEncoder().encode(values), as: UTF8.self) }
}
#endif
