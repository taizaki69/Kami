import Foundation

#if canImport(SQLite3)
enum LibraryNotificationPersistence {
    static func read(_ db: SQLiteDatabase) throws -> LibraryNotificationSettings {
        guard let row = try db.query("SELECT * FROM library_notification_state WHERE singleton=1").first,
              let enabled = row.int("enabled"), (0...1).contains(enabled),
              let revision = row.int64("revision"), revision > 0,
              let cursor = row.int64("scan_cursor"), cursor >= 0,
              let count = row.int("chapter_count"), count >= 0,
              let incomplete = row.int("incomplete"), (0...1).contains(incomplete) else {
            throw LibraryNotificationError.storageUnavailable
        }
        var batch: LibraryNotificationBatch?
        var outcome: LibraryNotificationOutcome?
        if let text = row.string("batch_id") {
            guard text.utf8.count == 36, let id = UUID(uuidString: text), count > 0,
                  let raw = row.string("outcome"), let value = LibraryNotificationOutcome(rawValue: raw) else {
                throw LibraryNotificationError.storageUnavailable
            }
            batch = .init(id: id, chapterCount: count, incomplete: incomplete == 1)
            outcome = value
        } else if !row.isNull("outcome") || count != 0 { throw LibraryNotificationError.storageUnavailable }
        return .init(enabled: enabled == 1, revision: revision, batch: batch, outcome: outcome)
    }

    static func save(_ db: SQLiteDatabase, enabled: Bool, expectedRevision: Int64) throws -> LibraryNotificationSettings {
        let old = try read(db)
        guard old.revision == expectedRevision, old.revision < Int64.max else { throw LibraryNotificationError.settingsChanged }
        // Every explicit save invalidates other retained editors (including ABA).
        // A real toggle excludes all scans already started before the choice.
        if old.enabled != enabled {
            try db.run("""
                UPDATE library_notification_state SET enabled=?,revision=revision+1,
                    scan_cursor=(SELECT COALESCE(MAX(rowid),0) FROM library_update_scan),
                    batch_id=NULL,chapter_count=0,incomplete=0,outcome=NULL WHERE singleton=1
                """, [.int(enabled ? 1 : 0)])
        } else { try db.run("UPDATE library_notification_state SET revision=revision+1 WHERE singleton=1") }
        try Task.checkCancellation()
        return try read(db)
    }

    static func claim(_ db: SQLiteDatabase, expectedRevision: Int64) throws -> LibraryNotificationBatch? {
        let settings = try read(db)
        guard settings.enabled, settings.revision == expectedRevision else { throw LibraryNotificationError.settingsChanged }
        guard settings.outcome != .attempting else { throw LibraryNotificationError.busy }
        let cursor = try db.query("SELECT scan_cursor FROM library_notification_state WHERE singleton=1").first!.int64("scan_cursor")!
        // Bound allocation and work per pass. Never move past a live scan.
        let rows = try db.query("""
            SELECT rowid,scan_id,status FROM library_update_scan WHERE rowid>? ORDER BY rowid LIMIT 100
            """, [.int(cursor)])
        var frontier = cursor, count = 0, incomplete = false
        for row in rows {
            try Task.checkCancellation()
            guard let sequence = row.int64("rowid"), sequence > frontier,
                  let id = row.string("scan_id"), UUID(uuidString: id) != nil,
                  let raw = row.string("status"), let status = LibraryUpdateScanStatus(rawValue: raw) else {
                throw LibraryNotificationError.storageUnavailable
            }
            if status == .running { break }
            let totals = try db.query("""
                SELECT COALESCE(SUM(CASE WHEN outcome='checked' AND established_baseline=0 THEN new_chapters ELSE 0 END),0) AS chapters,
                       COALESCE(SUM(CASE WHEN outcome IN ('failed','cancelled') THEN 1 ELSE 0 END),0) AS issues
                FROM library_update_target WHERE scan_id=?
                """, [.text(id)]).first
            guard let added = totals?.int("chapters"), added >= 0 else { throw LibraryNotificationError.storageUnavailable }
            let sum = count.addingReportingOverflow(added)
            guard !sum.overflow else { throw LibraryNotificationError.storageUnavailable }
            count = sum.partialValue
            incomplete = incomplete || status != .completed || (totals?.int("issues") ?? 0) > 0
            frontier = sequence
        }
        guard frontier > cursor else { return nil }
        try db.run("UPDATE library_notification_state SET scan_cursor=? WHERE singleton=1", [.int(frontier)])
        guard count > 0 else { try Task.checkCancellation(); return nil }
        let batch = LibraryNotificationBatch(id: UUID(), chapterCount: count, incomplete: incomplete)
        // Claim is committed BEFORE the OS call: ambiguous submissions are never
        // blindly replayed. Accepted scheduling does not prove user-visible delivery.
        try db.run("""
            UPDATE library_notification_state SET batch_id=?,chapter_count=?,incomplete=?,outcome='attempting' WHERE singleton=1
            """, [.text(batch.id.uuidString), .int(count), .int(incomplete ? 1 : 0)])
        try Task.checkCancellation()
        return batch
    }

    static func finish(_ db: SQLiteDatabase, id: UUID, outcome: LibraryNotificationOutcome) throws {
        guard outcome != .attempting else { throw LibraryNotificationError.storageUnavailable }
        try db.run("""
            UPDATE library_notification_state SET outcome=? WHERE singleton=1 AND batch_id=? AND outcome='attempting'
            """, [.text(outcome.rawValue), .text(id.uuidString)])
        try Task.checkCancellation()
    }
}
#endif
