import Foundation
import MihonCompatKit

#if canImport(SQLite3)
/// All entry points run inside the owning LibraryStore transaction. This code
/// never activates a source, rewrites configuration or touches downloaded files.
enum LibraryRestorePersistence {
    typealias Document = LibraryBackupDocument
    struct State {
        let document: Document
        let binding: Document.ContentBinding?
        let epoch: LibraryDataEpoch
        let digest: String
    }
    private static let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func state(_ db: SQLiteDatabase, policy: LibraryBackupPolicy) throws -> State {
        try Task.checkCancellation()
        let epoch = try ReadingStateReader.epoch(db)
        let storedBinding = try SourceContentBindingPersistence.read(db)
        let binding = storedBinding.map { Document.ContentBinding(
            kind: $0.kind == .deployment ? .deployment : .unresolved, deploymentURL: $0.deploymentURL) }
        let document = try LibraryBackupSnapshotReader.read(db, exportID: snapshotID, exportedAt: 0,
            policy: policy, foolSlideBinding: {
                guard let binding else { throw LibraryRestoreError.invalidStoredData }
                return binding
            })
        guard try db.query("""
            SELECT 1 FROM manga WHERE typeof(library_revision)!='integer' OR library_revision<0 LIMIT 1
            """).isEmpty else { throw LibraryRestoreError.invalidStoredData }
        try validateMetadata(db)
        let encoded = try LibraryBackupCodec(policy: policy).encode(document)
        var hashes = [APKSignatureVerifier.apkSHA256(Array(encoded))]
        let projections: [(String, Int, Int)] = [
            ("SELECT id,source_id,url,library_revision FROM manga ORDER BY id", policy.maximumManga, policy.maximumURLBytes),
            ("SELECT id,manga_id,url FROM chapter ORDER BY id", policy.maximumChapters, policy.maximumURLBytes),
            ("SELECT id,name,sort_order FROM category ORDER BY id", policy.maximumCategories, policy.maximumLabelBytes),
            ("SELECT * FROM library_data_state ORDER BY singleton", 1, 16),
            ("SELECT * FROM source_content_binding ORDER BY source_id", 1, policy.maximumURLBytes),
            ("SELECT * FROM installed_extension ORDER BY package_name COLLATE BINARY", 10_000, 16_384),
            ("SELECT * FROM installed_extension_preferences ORDER BY package_name COLLATE BINARY", 10_000, 16_384),
            ("SELECT * FROM source_preference ORDER BY source_id,key COLLATE BINARY", 10_000, 16_384),
            ("SELECT * FROM extension_repo ORDER BY url COLLATE BINARY", 1_000, 16_384),
        ]
        var remaining = min(policy.maximumInputBytes, 64 * 1_024 * 1_024)
        for (sql, rows, columnBytes) in projections {
            try Task.checkCancellation()
            let bytes = try db.restoreDependencyBytes(sql, maximumRows: rows,
                maximumColumnBytes: columnBytes, maximumBytes: remaining)
            remaining -= bytes.count
            hashes.append(APKSignatureVerifier.apkSHA256(bytes))
        }
        return .init(document: document, binding: binding, epoch: epoch,
                     digest: APKSignatureVerifier.apkSHA256(Array(hashes.joined().utf8)))
    }

    /// These records are preserved, never imported. Validate their storage
    /// types before treating their byte fingerprint as a configuration snapshot.
    private static func validateMetadata(_ db: SQLiteDatabase) throws {
        func check(_ table: String, integers: [String], texts: [String], nullable: [String] = [], extra: [String] = []) throws {
            let maximum = table == "extension_repo" ? 1_000 : 10_000
            guard let count = try db.query("SELECT COUNT(*) AS n FROM (SELECT 1 FROM \(table) LIMIT ?)",
                                           [.int(maximum + 1)]).first?.int64("n"), count <= Int64(maximum) else {
                throw LibraryRestoreError.resultLimitExceeded
            }
            try Task.checkCancellation()
            let valid = (integers.map { "typeof(\($0))='integer'" }
                + texts.map { "typeof(\($0))='text'" }
                + nullable.map { "(\($0) IS NULL OR typeof(\($0))='text')" } + extra).joined(separator: " AND ")
            guard try db.query("SELECT 1 FROM \(table) WHERE CASE WHEN \(valid) THEN 0 ELSE 1 END=1 LIMIT 1").isEmpty else {
                throw LibraryRestoreError.invalidStoredData
            }
        }
        try check("installed_extension", integers: ["version_code", "installed_at", "enabled"],
            texts: ["package_name", "version_name", "apk_path", "apk_sha256", "signature_scheme",
                    "current_signers", "signer_history", "trust_source", "source_ids"], nullable: ["repo_url"],
            extra: ["enabled IN (0,1)", "version_code>=0", "installed_at>=0"])
        try check("installed_extension_preferences", integers: ["schema_revision", "revision"],
            texts: ["package_name", "identity_fingerprint", "user_values"],
            extra: ["schema_revision>0", "revision>0", "length(CAST(identity_fingerprint AS BLOB))=64"])
        try check("source_preference", integers: ["source_id"], texts: ["key", "value"])
        try check("extension_repo", integers: ["added_at", "trusted"], texts: ["url", "name"],
            nullable: ["signing_key"], extra: ["trusted IN (0,1)", "added_at>=0"])
    }

    static func requireIdle(_ db: SQLiteDatabase) throws {
        try Task.checkCancellation()
        guard try db.query("SELECT 1 FROM library_update_scan WHERE status='running' LIMIT 1").isEmpty,
              try db.query("SELECT 1 FROM download_job WHERE state=1 OR publication_state IN ('working','prepared') LIMIT 1").isEmpty else {
            throw LibraryRestoreError.activeWork
        }
    }

    static func write(_ db: SQLiteDatabase, plan: LibraryRestorePlan) throws {
        try Task.checkCancellation()
        if let binding = plan.newFoolSlideBinding {
            guard try SourceContentBindingPersistence.read(db) == nil else { throw LibraryRestoreError.previewExpired }
            try db.run("INSERT INTO source_content_binding(source_id,kind,deployment_url,revision) VALUES (?,?,?,1)",
                [.int(SourceContentBindingPersistence.sourceID), .text(binding.kind.rawValue), text(binding.deploymentURL)])
        }
        var categories: [(id: Int64, name: String)] = try db.query(
            "SELECT id,CAST(name AS BLOB) AS name FROM category ORDER BY sort_order,id").map {
                guard let id = $0.int64("id"), let bytes = $0.bytes("name"), let name = String(bytes: bytes, encoding: .utf8) else {
                    throw LibraryRestoreError.invalidStoredData
                }
                return (id, name)
            }
        var categoryIDs: [Data: Int64] = [:]
        for category in plan.document.categories {
            try Task.checkCancellation()
            if let existing = categories.first(where: { Category.namesMatch($0.name, category.name) }) {
                categoryIDs[Data(category.key.utf8)] = existing.id
            } else {
                let id = try db.insert("INSERT INTO category(name,sort_order,flags) VALUES (?,?,?)",
                                      [.text(category.name), .int(category.sortOrder), .int(category.flags)])
                categories.append((id, category.name)); categoryIDs[Data(category.key.utf8)] = id
            }
        }
        for manga in plan.document.manga where plan.affectedManga.contains(.init(manga)) {
            try Task.checkCancellation()
            let id: Int64
            if let existing = try ReadingStateReader.mangaID(db, sourceID: manga.sourceID, url: manga.url) {
                id = existing
                if manga.inLibrary {
                    guard let row = try db.query("SELECT in_library,library_revision FROM manga WHERE id=?", [.int(id)]).first,
                          let revision = row.int64("library_revision"), row.int64("in_library") == 1 || revision < Int64.max else {
                        throw LibraryRestoreError.invalidStoredData
                    }
                    try db.run("UPDATE manga SET in_library=1 WHERE id=? AND in_library=0", [.int(id)])
                }
            } else {
                id = try db.insert("""
                    INSERT INTO manga(source_id,url,title,alt_titles,thumbnail_url,author,artist,description,
                        genres,status,in_library,date_added,date_updated,last_fetched,update_strategy,initialized)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.int(manga.sourceID), .text(manga.url), .text(manga.title), .text(try json(manga.altTitles)),
                          text(manga.thumbnailURL), text(manga.author), text(manga.artist), text(manga.descriptionText),
                          .text(try json(manga.genres)), .int(manga.status.rawValue), .bool(manga.inLibrary),
                          .int(manga.dateAdded), .int(manga.dateUpdated), .int(manga.lastFetched),
                          .text(manga.updateStrategy.rawValue), .bool(manga.initialized)])
            }
            for key in manga.categoryKeys {
                guard let categoryID = categoryIDs[Data(key.utf8)] else { throw LibraryRestoreError.invalidStoredData }
                try db.run("INSERT OR IGNORE INTO manga_category(manga_id,category_id) VALUES (?,?)", [.int(id), .int(categoryID)])
            }
            var chapterIDs: [Data: Int64] = [:]
            for chapter in manga.chapters {
                try Task.checkCancellation()
                let chapterID: Int64
                let existing = try db.query("SELECT id FROM chapter WHERE manga_id=? AND CAST(url AS BLOB)=? LIMIT 2",
                                           [.int(id), .blob(Array(chapter.url.utf8))])
                guard existing.count <= 1 else { throw LibraryRestoreError.invalidStoredData }
                if let row = existing.first {
                    guard let savedID = row.int64("id") else { throw LibraryRestoreError.invalidStoredData }
                    chapterID = savedID
                    try db.run("""
                        UPDATE chapter SET read=?,bookmark=?,last_page_read=? WHERE id=?
                            AND (read!=? OR bookmark!=? OR last_page_read!=?)
                        """, [.bool(chapter.read), .bool(chapter.bookmark), .int(chapter.lastPageRead), .int(chapterID),
                              .bool(chapter.read), .bool(chapter.bookmark), .int(chapter.lastPageRead)])
                } else {
                    chapterID = try db.insert("""
                        INSERT INTO chapter(manga_id,source_order,url,name,scanlator,number,date_upload,date_fetch,
                            read,bookmark,last_page_read,is_current) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [.int(id), .int(chapter.sourceOrder), .text(chapter.url), .text(chapter.name), text(chapter.scanlator),
                              .double(chapter.number), .int(chapter.dateUpload), .int(chapter.dateFetch), .bool(chapter.read),
                              .bool(chapter.bookmark), .int(chapter.lastPageRead), .bool(chapter.isCurrent)])
                }
                chapterIDs[Data(chapter.url.utf8)] = chapterID
            }
            for item in manga.history {
                try Task.checkCancellation()
                guard let chapterID = chapterIDs[Data(item.chapterURL.utf8)] else { throw LibraryRestoreError.invalidStoredData }
                try db.run("""
                    INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,?,?)
                    ON CONFLICT(manga_id,chapter_id) DO UPDATE SET last_read=excluded.last_read,read_duration=excluded.read_duration
                    WHERE history.last_read!=excluded.last_read OR history.read_duration!=excluded.read_duration
                    """, [.int(id), .int(chapterID), .int(item.lastRead), .int(item.readDuration)])
            }
            if let baseline = manga.discoveryBaseline {
                try db.run("INSERT OR IGNORE INTO chapter_discovery_baseline(manga_id,established_at) VALUES (?,?)",
                           [.int(id), .int(baseline.establishedAt)])
            }
            for item in manga.knownChapters {
                try Task.checkCancellation()
                try db.run("INSERT OR IGNORE INTO known_chapter(manga_id,url,first_seen,detected_at) VALUES (?,?,?,?)",
                           [.int(id), .text(item.url), .int(item.firstSeen), item.detectedAt.map(SQLiteBindable.int) ?? .null])
            }
        }
    }

    private static func text(_ value: String?) -> SQLiteBindable { value.map(SQLiteBindable.text) ?? .null }
    private static func json(_ value: [String]) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}
#endif
