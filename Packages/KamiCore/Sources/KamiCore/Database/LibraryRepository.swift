import Foundation
import MihonCompatKit

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
        if let existing = try self.manga(sourceId: manga.sourceId, url: manga.url),
           let existingId = existing.id {
            var merged = manga
            merged.id = existingId
            merged.inLibrary = inLibrary ?? existing.inLibrary
            if merged.dateAdded == 0 { merged.dateAdded = existing.dateAdded }
            if merged.dateUpdated == 0 { merged.dateUpdated = existing.dateUpdated }
            return try upsert(merged, inLibrary: merged.inLibrary)
        }
        return try db.insert("""
            INSERT INTO manga
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
            let existing = try db.query(
                "SELECT id, url FROM chapter WHERE manga_id=?", [.int(mangaId)]
            )
            var idsByURL: [String: Int64] = [:]
            for row in existing {
                if let id = row.int64("id"), let url = row.string("url") {
                    idsByURL[url] = id
                }
            }

            for (order, ch) in chapters.enumerated() {
                if let id = idsByURL[ch.url] {
                    try db.run("""
                        UPDATE chapter SET source_order=?, name=?, scanlator=?, number=?, date_upload=?
                        WHERE id=?
                        """, [.int(order), .text(ch.name),
                              ch.scanlator.map { SQLiteBindable.text($0) } ?? .null,
                              .double(ch.number), .int(ch.dateUpload), .int(id)])
                } else {
                    _ = try db.insert("""
                        INSERT INTO chapter (manga_id, source_order, url, name, scanlator, number,
                                             date_upload, read, bookmark, last_page_read)
                        VALUES (?,?,?,?,?,?,?,?,?,?)
                        """, [.int(mangaId), .int(order), .text(ch.url), .text(ch.name),
                              ch.scanlator.map { SQLiteBindable.text($0) } ?? .null, .double(ch.number),
                              .int(ch.dateUpload), .bool(ch.read), .bool(ch.bookmark), .int(ch.lastPageRead)])
                }
            }

            let incomingURLs = Set(chapters.map(\.url))
            for row in existing {
                guard let id = row.int64("id"),
                      let url = row.string("url"),
                      !incomingURLs.contains(url) else { continue }
                try db.run("DELETE FROM chapter WHERE id=?", [.int(id)])
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
        return rows.compactMap { row -> (Manga, Chapter, Int64)? in
            guard let m = Self.manga(from: row),
                  let chapterId = row.int64("chapter_id"),
                  let chapterUrl = row.string("chapter_url"),
                  let chapterName = row.string("chapter_name"),
                  let lastRead = row.int64("last_read") else { return nil }
            return (m, Chapter(id: chapterId, mangaId: m.id ?? 0, url: chapterUrl, name: chapterName), lastRead)
        }
    }

    public func updateProgress(chapterId: Int64, page: Int) throws {
        try db.run("UPDATE chapter SET last_page_read=? WHERE id=?", [.int(page), .int(chapterId)])
    }

    // MARK: - Extension signer trust

    public func installedExtensionTrust(packageName: String) throws -> InstalledExtensionTrust? {
        guard let row = try db.query(
            "SELECT * FROM installed_extension WHERE package_name=? LIMIT 1",
            [.text(packageName)]
        ).first,
        let versionName = row.string("version_name"),
        let versionCode = row.int64("version_code"),
        let apkPath = row.string("apk_path"),
        let apkSHA256 = row.string("apk_sha256"), !apkSHA256.isEmpty,
        let schemeText = row.string("signature_scheme"),
        let scheme = APKSigningIdentity.Scheme(rawValue: schemeText),
        let currentSigners = Self.stringArray(row.string("current_signers")),
        !currentSigners.isEmpty,
        let signerHistory = Self.stringArray(row.string("signer_history")),
        !signerHistory.isEmpty,
        let trustText = row.string("trust_source"),
        let trustSource = ExtensionTrustSource(persistedValue: trustText) else {
            // Rows created before signer admission are intentionally not
            // executable until they are re-admitted and populated.
            return nil
        }
        return InstalledExtensionTrust(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode,
            apkPath: apkPath,
            apkSHA256: apkSHA256,
            signatureScheme: scheme,
            currentSigners: currentSigners,
            signerHistory: signerHistory,
            trustSource: trustSource,
            sourceIDs: Set(Self.int64Array(row.string("source_ids")))
        )
    }

    func commitExtensionAdmission(
        _ candidate: ExtensionAdmissionCandidate
    ) throws -> ExtensionAdmission {
        let existing = try installedExtensionTrust(packageName: candidate.packageName)
        let trustSource: ExtensionTrustSource
        if let existing {
            guard candidate.versionCode >= existing.versionCode else {
                throw ExtensionAdmissionError.downgrade(
                    installed: existing.versionCode,
                    candidate: candidate.versionCode
                )
            }
            if candidate.versionCode == existing.versionCode,
               candidate.apkSHA256 != existing.apkSHA256 {
                throw ExtensionAdmissionError.sameVersionContentMismatch
            }
            guard ExtensionAdmissionService.updatePreservesIdentity(
                existingCurrentSigners: existing.currentSigners,
                candidate: candidate.signingIdentity
            ) else {
                throw ExtensionAdmissionError.updateSignerMismatch
            }
            // Initial trust is sticky. Repository metadata may disappear or
            // change, but it cannot replace the package's persisted identity.
            trustSource = existing.trustSource
        } else {
            guard let presented = candidate.presentedTrustSource else {
                throw ExtensionAdmissionError.untrustedSigner(
                    candidate.signingIdentity.signers.map(\.currentFingerprint)
                )
            }
            trustSource = presented
        }

        let currentSigners = candidate.signingIdentity.signers
            .map(\.currentFingerprint)
            .sorted()
        let signerHistory = Array(candidate.signingIdentity.allFingerprints).sorted()
        let currentJSON = try Self.json(currentSigners)
        let historyJSON = try Self.json(signerHistory)
        let sourceJSON = try Self.json(candidate.sourceIDs.sorted())
        let now = Int64(Date().timeIntervalSince1970)
        try db.run("""
            INSERT INTO installed_extension
                (package_name, version_name, version_code, apk_path, repo_url,
                 installed_at, enabled, apk_sha256, signature_scheme,
                 current_signers, signer_history, trust_source, source_ids)
            VALUES (?,?,?,?,?,?,1,?,?,?,?,?,?)
            ON CONFLICT(package_name) DO UPDATE SET
                version_name=excluded.version_name,
                version_code=excluded.version_code,
                apk_path=excluded.apk_path,
                repo_url=excluded.repo_url,
                installed_at=excluded.installed_at,
                enabled=1,
                apk_sha256=excluded.apk_sha256,
                signature_scheme=excluded.signature_scheme,
                current_signers=excluded.current_signers,
                signer_history=excluded.signer_history,
                trust_source=excluded.trust_source,
                source_ids=excluded.source_ids
            """, [
                .text(candidate.packageName),
                .text(candidate.versionName),
                .int(candidate.versionCode),
                .text(candidate.apkPath),
                candidate.repositoryURL.map(SQLiteBindable.text) ?? .null,
                .int(now),
                .text(candidate.apkSHA256),
                .text(candidate.signingIdentity.scheme.rawValue),
                .text(currentJSON),
                .text(historyJSON),
                .text(trustSource.persistedValue),
                .text(sourceJSON),
            ])

        return ExtensionAdmission(
            packageName: candidate.packageName,
            versionName: candidate.versionName,
            versionCode: candidate.versionCode,
            apkPath: candidate.apkPath,
            apkSHA256: candidate.apkSHA256,
            signingIdentity: candidate.signingIdentity,
            trustSource: trustSource,
            sourceIDs: candidate.sourceIDs
        )
    }

    // MARK: - Row mapping

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func stringArray(_ value: String?) -> [String] {
        guard let data = value?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func int64Array(_ value: String?) -> [Int64] {
        guard let data = value?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int64].self, from: data)) ?? []
    }

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
