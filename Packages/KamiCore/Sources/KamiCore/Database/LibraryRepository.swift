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

    /// Metadata refresh preserves membership changed during a source request.
    /// Pass inLibrary explicitly or use setLibrary for a membership mutation.
    @discardableResult
    public func upsert(_ manga: Manga, inLibrary: Bool? = nil) throws -> Int64 {
        let alt = (try? String(data: JSONEncoder().encode(manga.altTitles), encoding: .utf8)) ?? "[]"
        let genres = (try? String(data: JSONEncoder().encode(manga.genres), encoding: .utf8)) ?? "[]"
        if let id = manga.id {
            try db.run("""
                UPDATE manga SET title=?, alt_titles=?, thumbnail_url=?, author=?, artist=?,
                    description=?, genres=?, status=?, in_library=COALESCE(?, in_library), update_strategy=?, date_updated=?
                WHERE id=?
                """, [.text(manga.title), .text(alt), manga.thumbnailURL.map { SQLiteBindable.text($0) } ?? .null,
                      manga.author.map { SQLiteBindable.text($0) } ?? .null, manga.artist.map { SQLiteBindable.text($0) } ?? .null,
                      manga.descriptionText.map { SQLiteBindable.text($0) } ?? .null, .text(genres), .int(Int64(manga.status.rawValue)),
                      inLibrary.map(SQLiteBindable.bool) ?? .null, .text(manga.updateStrategy.rawValue),
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
            return try upsert(merged, inLibrary: inLibrary)
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
        try withLibraryTransaction {
            try db.run("UPDATE manga SET in_library=? WHERE id=?", [.bool(inLibrary), .int(mangaId)])
            if !inLibrary {
                try db.run("DELETE FROM manga_category WHERE manga_id=?", [.int(mangaId)])
            }
        }
    }

    // MARK: - Categories

    public func categories() throws -> [Category] {
        try db.query("SELECT id, name, sort_order FROM category ORDER BY sort_order, id")
            .compactMap { row in
                guard let id = row.int64("id"), let name = row.string("name") else { return nil }
                return Category(id: id, name: name, order: row.int("sort_order") ?? 0)
            }
    }

    public func librarySnapshot() throws -> LibrarySnapshot {
        try withLibraryTransaction(readOnly: true) {
            let manga = try libraryManga()
            let categories = try self.categories()
            let rows = try db.query("""
                SELECT mc.manga_id, mc.category_id FROM manga_category mc
                JOIN manga m ON m.id = mc.manga_id WHERE m.in_library = 1
                """)
            var membership: [Int64: Set<Int64>] = [:]
            for row in rows {
                guard let mangaID = row.int64("manga_id"),
                      let categoryID = row.int64("category_id") else { continue }
                membership[mangaID, default: []].insert(categoryID)
            }
            return LibrarySnapshot(manga: manga, categories: categories,
                                   categoryIDsByManga: membership)
        }
    }

    @discardableResult
    public func createCategory(name: String) throws -> Category {
        let name = try Category.validatedName(name)
        return try withLibraryTransaction {
            let existing = try categories()
            guard !existing.contains(where: { Category.namesMatch($0.name, name) }) else {
                throw LibraryCategoryError.duplicateName
            }
            try persistCategoryOrder(existing.compactMap(\.id))
            let id = try db.insert(
                "INSERT INTO category (name, sort_order) VALUES (?,?)",
                [.text(name), .int(existing.count)]
            )
            return Category(id: id, name: name, order: existing.count)
        }
    }

    public func renameCategory(id: Int64, name: String) throws {
        let name = try Category.validatedName(name)
        try withLibraryTransaction {
            let existing = try categories()
            guard existing.contains(where: { $0.id == id }) else {
                throw LibraryCategoryError.categoryNotFound(id)
            }
            guard !existing.contains(where: { $0.id != id && Category.namesMatch($0.name, name) }) else {
                throw LibraryCategoryError.duplicateName
            }
            try db.run("UPDATE category SET name=? WHERE id=?", [.text(name), .int(id)])
        }
    }

    public func reorderCategories(ids: [Int64]) throws {
        try withLibraryTransaction {
            try Category.validateOrder(ids, existingIDs: Set(try categories().compactMap(\.id)))
            try persistCategoryOrder(ids)
        }
    }

    /// Foreign-key cascading removes only the category's associations.
    /// Manga rows, chapter state, and history are never deleted here.
    public func deleteCategories(ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        try withLibraryTransaction {
            let existing = try categories()
            try validateCategoryIDs(ids, categories: existing)
            for id in ids.sorted() {
                try db.run("DELETE FROM category WHERE id=?", [.int(id)])
            }
            try persistCategoryOrder(existing.compactMap(\.id).filter { !ids.contains($0) })
        }
    }

    public func setCategories(_ categoryIDs: Set<Int64>, mangaId: Int64) throws {
        try setCategories(categoryIDs, mangaIDs: [mangaId])
    }

    /// Replaces membership atomically after validating every manga and category.
    public func setCategories(_ categoryIDs: Set<Int64>, mangaIDs: Set<Int64>) throws {
        guard !mangaIDs.isEmpty else { return }
        try withLibraryTransaction {
            try validateCategoryIDs(categoryIDs, categories: categories())
            try validateLibraryMangaIDs(mangaIDs)
            for mangaID in mangaIDs.sorted() {
                try db.run("DELETE FROM manga_category WHERE manga_id=?", [.int(mangaID)])
                for categoryID in categoryIDs.sorted() {
                    try db.run("INSERT INTO manga_category (manga_id, category_id) VALUES (?,?)",
                               [.int(mangaID), .int(categoryID)])
                }
            }
        }
    }

    /// Applies explicit bulk changes while preserving every untouched category.
    public func updateCategories(
        adding: Set<Int64>,
        removing: Set<Int64>,
        mangaIDs: Set<Int64>
    ) throws {
        guard adding.isDisjoint(with: removing) else {
            throw LibraryCategoryError.conflictingCategoryChanges
        }
        guard !mangaIDs.isEmpty else { return }
        try withLibraryTransaction {
            try validateCategoryIDs(adding.union(removing), categories: categories())
            try validateLibraryMangaIDs(mangaIDs)
            for mangaID in mangaIDs.sorted() {
                for categoryID in removing.sorted() {
                    try db.run("DELETE FROM manga_category WHERE manga_id=? AND category_id=?",
                               [.int(mangaID), .int(categoryID)])
                }
                for categoryID in adding.sorted() {
                    try db.run("INSERT OR IGNORE INTO manga_category (manga_id, category_id) VALUES (?,?)",
                               [.int(mangaID), .int(categoryID)])
                }
            }
        }
    }

    private func validateCategoryIDs(_ ids: Set<Int64>, categories: [Category]) throws {
        let known = Set(categories.compactMap(\.id))
        if let missing = ids.subtracting(known).sorted().first {
            throw LibraryCategoryError.categoryNotFound(missing)
        }
    }

    private func validateLibraryMangaIDs(_ ids: Set<Int64>) throws {
        let known = Set(try db.query("SELECT id FROM manga WHERE in_library=1")
            .compactMap { $0.int64("id") })
        if let missing = ids.subtracting(known).sorted().first {
            throw LibraryCategoryError.mangaNotInLibrary(missing)
        }
    }

    private func persistCategoryOrder(_ ids: [Int64]) throws {
        for (order, id) in ids.enumerated() {
            try db.run("UPDATE category SET sort_order=? WHERE id=?", [.int(order), .int(id)])
        }
    }

    private func withLibraryTransaction<T>(
        readOnly: Bool = false,
        _ operation: () throws -> T
    ) throws -> T {
        try db.execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Chapters

    public func chapters(mangaId: Int64) throws -> [Chapter] {
        try db.query("SELECT * FROM chapter WHERE manga_id=? AND is_current=1 ORDER BY source_order", [.int(mangaId)])
            .compactMap(Self.chapter(from:))
    }

    public func replaceChapters(mangaId: Int64, with chapters: [Chapter]) throws {
        try withLibraryTransaction {
            try replaceChaptersInTransaction(mangaId: mangaId, with: chapters)
            try establishInitialChapterBaseline(mangaId: mangaId)
        }
    }

    private func replaceChaptersInTransaction(mangaId: Int64, with chapters: [Chapter]) throws {
        let existing = try db.query(
            "SELECT id, url FROM chapter WHERE manga_id=?", [.int(mangaId)]
        )
        var idsByURL: [String: Int64] = [:]
        for row in existing {
            if let id = row.int64("id"), let url = row.string("url") {
                idsByURL[url] = id
            }
        }

        // A source may repeat a URL. Preserve its first metadata/order and
        // never write or count the same discovery twice.
        var acceptedURLs: Set<String> = []
        let unique = chapters.filter { acceptedURLs.insert($0.url).inserted }
        for (order, ch) in unique.enumerated() {
            if let id = idsByURL[ch.url] {
                try db.run("""
                    UPDATE chapter SET source_order=?, name=?, scanlator=?, number=?, date_upload=?, is_current=1
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

        let incomingURLs = Set(unique.map(\.url))
        for row in existing {
            guard let id = row.int64("id"),
                  let url = row.string("url"),
                  !incomingURLs.contains(url) else { continue }
            // Keep reading state and history if the URL later reappears.
            try db.run("UPDATE chapter SET is_current=0 WHERE id=?", [.int(id)])
        }
    }

    /// The source/configuration check and every source-result write share the
    /// transaction. An obsolete runtime cannot insert a relative manga URL
    /// after a deployment change, even if its network result arrived later.
    public func persistSourceUpdate(
        manga: Manga,
        chapters: [SChapterCompat],
        expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> SourceMangaUpdate {
        try Task.checkCancellation()
        return try withLibraryTransaction {
            try verifySourceUpdateConfiguration(manga: manga, expectedConfiguration: expectedConfiguration)
            if let id = manga.id {
                guard let stored = try self.manga(id: id),
                      stored.sourceId == manga.sourceId, stored.url == manga.url else {
                    throw SourceUpdatePersistenceError.sourceIdentityMismatch
                }
            }
            let result = try persistSourceUpdateInTransaction(manga: manga, chapters: chapters)
            guard let id = result.manga.id else {
                throw SourceUpdatePersistenceError.sourceIdentityMismatch
            }
            _ = try recordChapterDiscoveries(mangaId: id, urls: chapters.map(\.url),
                                             announce: result.manga.inLibrary)
            try Task.checkCancellation()
            return result
        }
    }

    private func verifySourceUpdateConfiguration(
        manga: Manga,
        expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws {
        if let expectedConfiguration {
            try verifyExtensionExecutionConfigurationInTransaction(expectedConfiguration)
            guard expectedConfiguration.installed.sourceIDs.contains(manga.sourceId) else {
                throw SourceUpdatePersistenceError.sourceIdentityMismatch
            }
        } else {
            // Downloaded profiles cannot use nil to bypass their CAS token.
            guard manga.sourceId == MangaDexSource().id else {
                throw SourceUpdatePersistenceError.configurationRequired
            }
        }
    }

    private func persistSourceUpdateInTransaction(
        manga: Manga, chapters: [SChapterCompat]
    ) throws -> SourceMangaUpdate {
        let id = try upsert(manga)
        let incoming = chapters.enumerated().map { order, chapter in
            Chapter(mangaId: id, sourceOrder: order, from: chapter)
        }
        try replaceChaptersInTransaction(mangaId: id, with: incoming)
        guard let stored = try self.manga(id: id) else {
            throw SourceUpdatePersistenceError.sourceIdentityMismatch
        }
        return SourceMangaUpdate(manga: stored, chapters: try self.chapters(mangaId: id))
    }

    /// A first successful detail/list refresh also gives the next manual scan
    /// a historical baseline, including when the returned list was empty.
    private func establishInitialChapterBaseline(mangaId: Int64) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try db.run("INSERT OR IGNORE INTO chapter_discovery_baseline(manga_id,established_at) VALUES (?,?)",
                   [.int(mangaId), .int(now)])
        try db.run("""
            INSERT OR IGNORE INTO known_chapter(manga_id,url,first_seen,detected_at)
            SELECT manga_id,url,?,NULL FROM chapter WHERE manga_id=?
            """, [.int(now), .int(mangaId)])
    }

    private func recordChapterDiscoveries(
        mangaId: Int64, urls: [String], announce: Bool
    ) throws -> (newChapters: Int, establishedBaseline: Bool) {
        let baseline = try hasChapterBaseline(mangaId: mangaId)
        let known = Set(try db.query("SELECT url FROM known_chapter WHERE manga_id=?", [.int(mangaId)])
            .compactMap { $0.string("url") })
        var seen: Set<String> = []
        let unseen = urls.filter { seen.insert($0).inserted && !known.contains($0) }
        let now = Int64(Date().timeIntervalSince1970)
        let shouldAnnounce = baseline && announce
        for url in unseen {
            try db.run("INSERT INTO known_chapter(manga_id,url,first_seen,detected_at) VALUES (?,?,?,?)",
                       [.int(mangaId), .text(url), .int(now), shouldAnnounce ? .int(now) : .null])
        }
        if !baseline {
            try db.run("INSERT INTO chapter_discovery_baseline(manga_id,established_at) VALUES (?,?)",
                       [.int(mangaId), .int(now)])
        }
        return (shouldAnnounce ? unseen.count : 0, !baseline)
    }

    private func hasChapterBaseline(mangaId: Int64) throws -> Bool {
        try !db.query("SELECT 1 FROM chapter_discovery_baseline WHERE manga_id=?",
                      [.int(mangaId)]).isEmpty
    }

    // MARK: - Durable manual library updates

    public func beginLibraryUpdateScan() throws -> LibraryUpdateScanSnapshot {
        try Task.checkCancellation()
        return try withLibraryTransaction {
            guard try db.query("SELECT 1 FROM library_update_scan WHERE status='running'").isEmpty else {
                throw LibraryUpdatePersistenceError.scanAlreadyRunning
            }
            let mangas = try libraryManga()
            let scanID = UUID()
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("""
                INSERT INTO library_update_scan(scan_id,status,started_at,total)
                VALUES (?,'running',?,?)
                """, [.text(scanID.uuidString), .int(now), .int(mangas.count)])
            var items: [LibraryUpdateItem] = []
            for manga in mangas {
                guard let id = manga.id,
                      let revision = try db.query("SELECT library_revision FROM manga WHERE id=?",
                                                  [.int(id)]).first?.int64("library_revision") else {
                    throw LibraryUpdatePersistenceError.invalidStoredScan
                }
                try db.run("""
                    INSERT INTO library_update_target(scan_id,manga_id,title,library_revision)
                    VALUES (?,?,?,?)
                    """, [.text(scanID.uuidString), .int(id), .text(manga.title), .int(revision)])
                items.append(LibraryUpdateItem(manga: manga, hasSuccessfulBaseline: try hasChapterBaseline(mangaId: id)))
            }
            try Task.checkCancellation()
            return LibraryUpdateScanSnapshot(record: try readLibraryUpdateSummary(scanID), items: items)
        }
    }

    public func recordLibraryUpdateSuccess(
        scanID: UUID,
        manga: Manga,
        chapters: [SChapterCompat],
        expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> LibraryUpdateCommitResult {
        try Task.checkCancellation()
        return try withLibraryTransaction {
            let target = try activeLibraryUpdateTarget(scanID: scanID, mangaID: manga.id)
            guard let mangaID = target.int64("manga_id") else {
                throw LibraryUpdatePersistenceError.invalidStoredScan
            }
            switch target.string("outcome") {
            case "checked":
                return LibraryUpdateCommitResult(
                    summary: try readLibraryUpdateSummary(scanID),
                    outcome: .updated(newChapters: target.int("new_chapters") ?? 0,
                                      establishedBaseline: target.bool("established_baseline"))
                )
            case "skipped":
                return LibraryUpdateCommitResult(summary: try readLibraryUpdateSummary(scanID),
                                                 outcome: .skippedNotInLibrary)
            case "pending": break
            default: throw LibraryUpdatePersistenceError.targetAlreadyRecorded
            }
            // The revision rejects a result even if a manga was removed and
            // re-added while its request was in flight.
            let membership = try db.query("SELECT in_library,library_revision FROM manga WHERE id=?",
                                          [.int(mangaID)]).first
            guard membership?.bool("in_library") == true,
                  membership?.int64("library_revision") == target.int64("library_revision") else {
                try recordLibraryUpdateOutcome(scanID: scanID, mangaID: mangaID, outcome: .skipped,
                                               reason: .removedFromLibrary)
                return LibraryUpdateCommitResult(summary: try readLibraryUpdateSummary(scanID),
                                                 outcome: .skippedNotInLibrary)
            }
            guard let stored = try self.manga(id: mangaID),
                  stored.sourceId == manga.sourceId, stored.url == manga.url else {
                throw LibraryUpdatePersistenceError.sourceIdentityMismatch
            }
            try verifySourceUpdateConfiguration(manga: manga, expectedConfiguration: expectedConfiguration)
            var seen: Set<String> = []
            let unique = chapters.filter { seen.insert($0.url).inserted }
            let discovery = try recordChapterDiscoveries(mangaId: mangaID, urls: unique.map(\.url), announce: true)
            _ = try persistSourceUpdateInTransaction(manga: manga, chapters: unique)
            let newCount = discovery.newChapters
            try db.run("""
                UPDATE library_update_target SET outcome='checked',new_chapters=?,established_baseline=?
                WHERE scan_id=? AND manga_id=?
                """, [.int(newCount), .bool(discovery.establishedBaseline), .text(scanID.uuidString), .int(mangaID)])
            try Task.checkCancellation()
            return LibraryUpdateCommitResult(summary: try readLibraryUpdateSummary(scanID),
                                             outcome: .updated(newChapters: newCount,
                                                               establishedBaseline: discovery.establishedBaseline))
        }
    }

    /// Avoid fetching queued work removed since the library snapshot. The
    /// success transaction repeats this check because membership can still
    /// change after this read and during the request.
    public func libraryUpdateTargetIsCurrent(scanID: UUID, mangaID: Int64) throws -> Bool {
        try withLibraryTransaction(readOnly: true) {
            let target = try activeLibraryUpdateTarget(scanID: scanID, mangaID: mangaID)
            guard target.string("outcome") == "pending",
                  let membership = try db.query("SELECT in_library,library_revision FROM manga WHERE id=?",
                                                [.int(mangaID)]).first else { return false }
            return membership.bool("in_library")
                && membership.int64("library_revision") == target.int64("library_revision")
        }
    }

    public func recordLibraryUpdateSkip(
        scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason
    ) throws -> LibraryUpdateSummary {
        guard [.sourceUnavailable, .configurationChanged, .onlyFetchOnce, .removedFromLibrary].contains(reason) else {
            throw LibraryUpdatePersistenceError.invalidTargetReason
        }
        return try withLibraryTransaction {
            let target = try activeLibraryUpdateTarget(scanID: scanID, mangaID: mangaID)
            if target.string("outcome") == "pending" {
                try recordLibraryUpdateOutcome(scanID: scanID, mangaID: mangaID, outcome: .skipped, reason: reason)
            }
            return try readLibraryUpdateSummary(scanID)
        }
    }

    public func recordLibraryUpdateFailure(
        scanID: UUID, mangaID: Int64, reason: LibraryUpdateTargetReason = .requestFailed
    ) throws -> LibraryUpdateSummary {
        guard [.requestFailed, .configurationChanged].contains(reason) else {
            throw LibraryUpdatePersistenceError.invalidTargetReason
        }
        return try withLibraryTransaction {
            let target = try activeLibraryUpdateTarget(scanID: scanID, mangaID: mangaID)
            if target.string("outcome") == "pending" {
                let membership = try db.query("SELECT in_library,library_revision FROM manga WHERE id=?",
                                              [.int(mangaID)]).first
                let current = membership?.bool("in_library") == true
                    && membership?.int64("library_revision") == target.int64("library_revision")
                try recordLibraryUpdateOutcome(scanID: scanID, mangaID: mangaID,
                                               outcome: current ? .failed : .skipped,
                                               reason: current ? reason : .removedFromLibrary)
            }
            return try readLibraryUpdateSummary(scanID)
        }
    }

    /// Terminal writes invalidate pending callbacks. Repeating finish after a
    /// worker/cancel race returns the existing terminal result unchanged.
    public func finishLibraryUpdateScan(
        scanID: UUID, status: LibraryUpdateScanStatus
    ) throws -> LibraryUpdateSummary {
        guard status == .completed || status == .cancelled else {
            throw LibraryUpdatePersistenceError.invalidTerminalStatus
        }
        return try withLibraryTransaction {
            let summary = try readLibraryUpdateSummary(scanID)
            guard summary.status == .running else { return summary }
            if status == .completed, summary.processedCount != summary.total {
                throw LibraryUpdatePersistenceError.unfinishedTargets
            }
            try terminateLibraryUpdateScan(scanID: scanID, status: status)
            return try readLibraryUpdateSummary(scanID)
        }
    }

    /// Call once on application/service recovery, never on an ordinary store
    /// open: another live connection may still own the running scan.
    @discardableResult
    public func recoverInterruptedLibraryUpdateScans() throws -> LibraryUpdateSummary? {
        try withLibraryTransaction {
            for row in try db.query("SELECT scan_id FROM library_update_scan WHERE status='running'") {
                guard let rawID = row.string("scan_id"), let scanID = UUID(uuidString: rawID) else {
                    throw LibraryUpdatePersistenceError.invalidStoredScan
                }
                try terminateLibraryUpdateScan(scanID: scanID, status: .interrupted)
            }
            return try latestLibraryUpdateSummary()
        }
    }

    public func libraryUpdatesSnapshot(
        discoveryLimit: Int = 500, after cursor: LibraryChapterDiscoveryCursor? = nil
    ) throws -> LibraryUpdatesSnapshot {
        try withLibraryTransaction(readOnly: true) {
            let limit = max(1, min(500, discoveryLimit))
            var parameters: [SQLiteBindable] = []
            let cursorPredicate: String
            if let cursor {
                cursorPredicate = "AND (k.detected_at,k.manga_id,k.url) < (?,?,?)"
                parameters = [.int(cursor.detectedAt), .int(cursor.mangaID), .text(cursor.chapterURL)]
            } else { cursorPredicate = "" }
            parameters.append(.int(limit + 1))
            let rows = try db.query("""
                SELECT m.*,k.detected_at,c.id AS chapter_id,c.manga_id AS chapter_manga_id,
                    c.url AS chapter_url,c.name AS chapter_name,c.source_order AS chapter_source_order,
                    c.scanlator AS chapter_scanlator,c.number AS chapter_number,
                    c.date_upload AS chapter_date_upload,c.read AS chapter_read,
                    c.bookmark AS chapter_bookmark,c.last_page_read AS chapter_last_page_read
                FROM known_chapter k
                JOIN manga m ON m.id=k.manga_id AND m.in_library=1
                JOIN chapter c ON c.manga_id=k.manga_id AND c.url=k.url AND c.is_current=1
                WHERE k.detected_at IS NOT NULL
                \(cursorPredicate)
                ORDER BY k.detected_at DESC,k.manga_id DESC,k.url DESC
                LIMIT ?
                """, parameters)
            let discoveries = rows.prefix(limit).compactMap { row -> LibraryChapterDiscovery? in
                guard let mangaID = row.int64("chapter_manga_id"), let chapterID = row.int64("chapter_id"),
                      let detectedAt = row.int64("detected_at"),
                      let manga = Self.manga(from: row), let chapterURL = row.string("chapter_url"),
                      let chapterName = row.string("chapter_name") else { return nil }
                let chapter = Self.joinedChapter(from: row, id: chapterID, mangaID: mangaID,
                                                 url: chapterURL, name: chapterName)
                return LibraryChapterDiscovery(manga: manga, chapter: chapter, detectedAt: detectedAt)
            }
            let hasMore = rows.count > limit
            let nextCursor = hasMore ? discoveries.last.map {
                LibraryChapterDiscoveryCursor(detectedAt: $0.detectedAt, mangaID: $0.chapter.mangaId,
                                              chapterURL: $0.chapter.url)
            } : nil
            let latest = try latestLibraryUpdateSummary()
            let issues: [LibraryUpdateIssue]
            if let latest {
                issues = try db.query("""
                    SELECT t.manga_id AS target_manga_id,t.title AS target_title,t.outcome,t.reason,m.*
                    FROM library_update_target t LEFT JOIN manga m ON m.id=t.manga_id
                    WHERE t.scan_id=? AND t.reason IS NOT NULL
                    ORDER BY t.title COLLATE NOCASE,t.manga_id
                    """, [.text(latest.scanID.uuidString)]).compactMap { row in
                        guard let mangaID = row.int64("target_manga_id"), let title = row.string("target_title"),
                              let outcomeText = row.string("outcome"),
                              let outcome = LibraryUpdateTargetOutcome(rawValue: outcomeText),
                              let reasonText = row.string("reason"),
                              let reason = LibraryUpdateTargetReason(rawValue: reasonText) else { return nil }
                        return LibraryUpdateIssue(mangaID: mangaID, title: title, manga: Self.manga(from: row),
                                                  outcome: outcome, reason: reason)
                    }
            } else { issues = [] }
            return LibraryUpdatesSnapshot(latestScan: latest, latestScanIssues: issues,
                                          discoveries: discoveries, hasMore: hasMore, nextCursor: nextCursor)
        }
    }

    private func activeLibraryUpdateTarget(scanID: UUID, mangaID: Int64?) throws -> SQLiteDatabase.Row {
        guard let scan = try db.query("SELECT status FROM library_update_scan WHERE scan_id=?",
                                       [.text(scanID.uuidString)]).first else {
            throw LibraryUpdatePersistenceError.scanNotFound
        }
        guard scan.string("status") == LibraryUpdateScanStatus.running.rawValue else {
            throw LibraryUpdatePersistenceError.scanNotRunning
        }
        guard let mangaID,
              let target = try db.query("SELECT * FROM library_update_target WHERE scan_id=? AND manga_id=?",
                                        [.text(scanID.uuidString), .int(mangaID)]).first else {
            throw LibraryUpdatePersistenceError.mangaNotInScan
        }
        return target
    }

    private func recordLibraryUpdateOutcome(
        scanID: UUID, mangaID: Int64, outcome: LibraryUpdateTargetOutcome, reason: LibraryUpdateTargetReason
    ) throws {
        try db.run("UPDATE library_update_target SET outcome=?,reason=? WHERE scan_id=? AND manga_id=?",
                   [.text(outcome.rawValue), .text(reason.rawValue), .text(scanID.uuidString), .int(mangaID)])
    }

    private func terminateLibraryUpdateScan(scanID: UUID, status: LibraryUpdateScanStatus) throws {
        try db.run("UPDATE library_update_target SET outcome='cancelled',reason='cancelled' WHERE scan_id=? AND outcome='pending'",
                   [.text(scanID.uuidString)])
        try db.run("UPDATE library_update_scan SET status=?,finished_at=? WHERE scan_id=?",
                   [.text(status.rawValue), .int(Int64(Date().timeIntervalSince1970)), .text(scanID.uuidString)])
    }

    private func latestLibraryUpdateSummary() throws -> LibraryUpdateSummary? {
        guard let rawID = try db.query(
            "SELECT scan_id FROM library_update_scan ORDER BY started_at DESC,rowid DESC LIMIT 1"
        ).first?.string("scan_id") else { return nil }
        guard let id = UUID(uuidString: rawID) else { throw LibraryUpdatePersistenceError.invalidStoredScan }
        return try readLibraryUpdateSummary(id)
    }

    private func readLibraryUpdateSummary(_ scanID: UUID) throws -> LibraryUpdateSummary {
        guard let row = try db.query("SELECT * FROM library_update_scan WHERE scan_id=?",
                                     [.text(scanID.uuidString)]).first else {
            throw LibraryUpdatePersistenceError.scanNotFound
        }
        guard let statusText = row.string("status"), let status = LibraryUpdateScanStatus(rawValue: statusText),
              let startedAt = row.int64("started_at"), let total = row.int("total") else {
            throw LibraryUpdatePersistenceError.invalidStoredScan
        }
        let counts = try db.query("""
            SELECT
                SUM(CASE WHEN outcome='checked' THEN 1 ELSE 0 END) AS checked,
                SUM(CASE WHEN outcome='skipped' THEN 1 ELSE 0 END) AS skipped,
                SUM(CASE WHEN outcome='failed' THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN outcome='cancelled' THEN 1 ELSE 0 END) AS cancelled,
                SUM(new_chapters) AS new_chapters,SUM(established_baseline) AS baselines
            FROM library_update_target WHERE scan_id=?
            """, [.text(scanID.uuidString)]).first
        return LibraryUpdateSummary(
            scanID: scanID, status: status, startedAt: startedAt, finishedAt: row.int64("finished_at"),
            total: total, checked: counts?.int("checked") ?? 0, newChapters: counts?.int("new_chapters") ?? 0,
            baselines: counts?.int("baselines") ?? 0, skipped: counts?.int("skipped") ?? 0,
            failed: counts?.int("failed") ?? 0, cancelled: counts?.int("cancelled") ?? 0
        )
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
            SELECT m.*, c.url AS chapter_url, c.name AS chapter_name, c.id AS chapter_id,h.last_read,
                c.source_order AS chapter_source_order,c.scanlator AS chapter_scanlator,
                c.number AS chapter_number,c.date_upload AS chapter_date_upload,
                c.read AS chapter_read,c.bookmark AS chapter_bookmark,c.last_page_read AS chapter_last_page_read
            FROM history h JOIN manga m ON m.id = h.manga_id JOIN chapter c ON c.id = h.chapter_id
            ORDER BY h.last_read DESC LIMIT 200
            """)
        return rows.compactMap { row -> (Manga, Chapter, Int64)? in
            guard let m = Self.manga(from: row),
                  let chapterId = row.int64("chapter_id"),
                  let chapterUrl = row.string("chapter_url"),
                  let chapterName = row.string("chapter_name"),
                  let lastRead = row.int64("last_read") else { return nil }
            return (m, Self.joinedChapter(from: row, id: chapterId, mangaID: m.id ?? 0,
                                          url: chapterUrl, name: chapterName), lastRead)
        }
    }

    public func updateProgress(chapterId: Int64, page: Int) throws {
        try db.run("UPDATE chapter SET last_page_read=? WHERE id=?", [.int(page), .int(chapterId)])
    }

    // MARK: - Extension repositories

    public func extensionRepositories() throws -> [ExtensionRepositoryRecord] {
        try db.query(
            "SELECT * FROM extension_repo ORDER BY added_at, url COLLATE NOCASE"
        ).compactMap { row in
            guard let url = row.string("url"),
                  let name = row.string("name") else { return nil }
            return ExtensionRepositoryRecord(
                url: url,
                name: name,
                signingKey: row.string("signing_key"),
                addedAt: row.int64("added_at") ?? 0
            )
        }
    }

    @discardableResult
    public func upsertExtensionRepository(
        url rawURL: String,
        name: String,
        signingKey rawSigningKey: String?
    ) throws -> ExtensionRepositoryRecord {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw ExtensionRepositoryRecordError.emptyURL }
        let candidateKey: String?
        if let rawSigningKey,
           !rawSigningKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidateKey = try APKSignatureVerifier.normalizeFingerprint(rawSigningKey)
        } else {
            candidateKey = nil
        }
        let existing = try db.query(
            "SELECT signing_key, added_at FROM extension_repo WHERE url=? LIMIT 1",
            [.text(url)]
        ).first
        let existingKey = existing?.string("signing_key")
        if let existingKey, let candidateKey, existingKey != candidateKey {
            throw ExtensionRepositoryRecordError.signingKeyChanged
        }
        let signingKey = existingKey ?? candidateKey
        let addedAt = existing?.int64("added_at") ?? Int64(Date().timeIntervalSince1970)
        try db.run("""
            INSERT INTO extension_repo (url, name, added_at, trusted, signing_key)
            VALUES (?,?,?,1,?)
            ON CONFLICT(url) DO UPDATE SET
                name=excluded.name,
                trusted=1,
                signing_key=excluded.signing_key
            """, [
                .text(url),
                .text(name),
                .int(addedAt),
                signingKey.map(SQLiteBindable.text) ?? .null,
            ])
        return ExtensionRepositoryRecord(
            url: url,
            name: name,
            signingKey: signingKey,
            addedAt: addedAt
        )
    }

    public func removeExtensionRepository(url: String) throws {
        try db.run("DELETE FROM extension_repo WHERE url=?", [.text(url)])
    }

    // MARK: - Extension signer trust

    public func installedExtensionTrust(packageName: String) throws -> InstalledExtensionTrust? {
        try db.query(
            "SELECT * FROM installed_extension WHERE package_name=? LIMIT 1",
            [.text(packageName)]
        ).first.flatMap { Self.installedExtensionTrust(from: $0) }
    }

    public func installedExtensionTrusts() throws -> [InstalledExtensionTrust] {
        try db.query(
            "SELECT * FROM installed_extension ORDER BY package_name COLLATE NOCASE"
        ).compactMap { Self.installedExtensionTrust(from: $0) }
    }

    public func setExtensionEnabled(_ enabled: Bool, packageName: String) throws {
        try db.run(
            "UPDATE installed_extension SET enabled=? WHERE package_name=?",
            [.bool(enabled), .text(packageName)]
        )
    }

    func commitExtensionAdmission(
        _ candidate: ExtensionAdmissionCandidate
    ) throws -> ExtensionAdmission {
        try withLibraryTransaction {
            try commitExtensionAdmissionInTransaction(candidate)
        }
    }

    private func commitExtensionAdmissionInTransaction(
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
        if let existing,
           existing.versionName != candidate.versionName
            || existing.versionCode != candidate.versionCode
            || existing.apkSHA256 != candidate.apkSHA256
            || existing.signatureScheme != candidate.signingIdentity.scheme
            || existing.currentSigners.sorted() != currentSigners
            || existing.signerHistory.sorted() != signerHistory
            || existing.sourceIDs != candidate.sourceIDs {
            // Signer continuity authenticates an update, but does not prove
            // that its new release has the same preference semantics.
            try db.run("DELETE FROM installed_extension_preferences WHERE package_name=?", [.text(candidate.packageName)])
        }
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

    // MARK: - Exact extension preference documents

    func verifyInstalledExtension(
        _ expected: InstalledExtensionTrust,
        requireEnabled: Bool = false
    ) throws {
        guard let current = try installedExtensionTrust(packageName: expected.packageName),
              current == expected,
              !requireEnabled || current.enabled else {
            throw ExtensionPreferencesError.staleInstallation
        }
    }

    func extensionConfigurationSnapshot(
        installed: InstalledExtensionTrust,
        schema: InterpretedExtensionPreferenceSchema
    ) throws -> ExtensionConfigurationSnapshot {
        try withLibraryTransaction(readOnly: true) {
            try verifyInstalledExtension(installed)
            return try readExtensionConfiguration(installed: installed, schema: schema)
        }
    }

    private func readExtensionConfiguration(
        installed: InstalledExtensionTrust,
        schema: InterpretedExtensionPreferenceSchema
    ) throws -> ExtensionConfigurationSnapshot {
        let fingerprint = try ExtensionPreferenceBinding.fingerprint(installed)
        // Select oversized/untyped payloads as NULL so the SQLite wrapper
        // never materializes an unbounded string from a corrupt database.
        let row = try db.query("""
            SELECT
                CASE WHEN typeof(identity_fingerprint)='text'
                    AND length(CAST(identity_fingerprint AS BLOB))=64
                    THEN identity_fingerprint ELSE NULL END AS identity_fingerprint,
                schema_revision, revision,
                CASE WHEN typeof(user_values)='text'
                    AND length(CAST(user_values AS BLOB))<=?
                    THEN user_values ELSE NULL END AS bounded_values
            FROM installed_extension_preferences WHERE package_name=? LIMIT 1
            """, [.int(StoredExtensionPreferenceValues.maximumBytes), .text(installed.packageName)]).first
        let userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value]
        let revision: Int64
        if let row {
            guard row.string("identity_fingerprint") == fingerprint,
                  row.int("schema_revision") == schema.revision,
                  let storedRevision = row.int64("revision"), storedRevision > 0,
                  let payload = row.string("bounded_values") else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            userValues = try StoredExtensionPreferenceValues.decode(payload, schema: schema).userValues
            revision = storedRevision
        } else {
            userValues = schema.defaultUserValues
            revision = 0
        }
        return ExtensionConfigurationSnapshot(
            installed: installed, schema: schema, userValues: userValues,
            identityFingerprint: fingerprint, revision: revision
        )
    }

    func saveExtensionConfiguration(
        snapshot: ExtensionConfigurationSnapshot,
        resolved: ResolvedExtensionPreferences
    ) throws -> ExtensionConfigurationSnapshot {
        guard resolved.profileIdentity == snapshot.schema.identity,
              resolved.schemaRevision == snapshot.schema.revision else {
            throw ExtensionPreferencesError.staleInstallation
        }
        let payload = try StoredExtensionPreferenceValues(resolved.userValues).encoded()
        return try withLibraryTransaction {
            try verifyInstalledExtension(snapshot.installed)
            let previous = try readExtensionConfiguration(installed: snapshot.installed, schema: snapshot.schema)
            guard previous.identityFingerprint == snapshot.identityFingerprint else {
                throw ExtensionPreferencesError.staleInstallation
            }
            guard previous.revision == snapshot.revision,
                  previous.userValues == snapshot.userValues else {
                throw ExtensionPreferencesError.staleConfiguration
            }
            let previousURL: String?
            if case let .string(value)? = previous.userValues[.baseURL] {
                previousURL = value
            } else {
                previousURL = nil
            }
            if previousURL != resolved.baseURL {
                for sourceID in snapshot.schema.identity.sourceIDs {
                    guard try db.query("SELECT 1 AS present FROM manga WHERE source_id=? LIMIT 1", [.int(sourceID)]).isEmpty else {
                        throw ExtensionPreferencesError.deploymentInUse
                    }
                }
            }
            guard snapshot.revision < Int64.max else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            let revision = snapshot.revision + 1
            try db.run("""
                INSERT INTO installed_extension_preferences
                    (package_name, identity_fingerprint, schema_revision, revision, user_values)
                VALUES (?,?,?,?,?)
                ON CONFLICT(package_name) DO UPDATE SET
                    identity_fingerprint=excluded.identity_fingerprint,
                    schema_revision=excluded.schema_revision,
                    revision=excluded.revision,
                    user_values=excluded.user_values
                """, [.text(snapshot.packageName), .text(snapshot.identityFingerprint),
                      .int(snapshot.schema.revision), .int(revision), .text(payload)])
            return ExtensionConfigurationSnapshot(
                installed: snapshot.installed, schema: snapshot.schema,
                userValues: resolved.userValues, identityFingerprint: snapshot.identityFingerprint,
                revision: revision
            )
        }
    }

    func verifyExtensionExecutionConfiguration(_ configuration: ExtensionExecutionConfiguration) throws {
        try withLibraryTransaction(readOnly: true) {
            try verifyExtensionExecutionConfigurationInTransaction(configuration)
        }
    }

    private func verifyExtensionExecutionConfigurationInTransaction(_ configuration: ExtensionExecutionConfiguration) throws {
        try verifyInstalledExtension(configuration.installed, requireEnabled: true)
        if let expected = configuration.snapshot {
            let current = try readExtensionConfiguration(installed: configuration.installed, schema: expected.schema)
            guard current == expected else { throw ExtensionPreferencesError.staleConfiguration }
        }
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

    private static func installedExtensionTrust(
        from row: SQLiteDatabase.Row
    ) -> InstalledExtensionTrust? {
        guard let packageName = row.string("package_name"),
              let versionName = row.string("version_name"),
              let versionCode = row.int64("version_code"),
              let apkPath = row.string("apk_path"),
              let apkSHA256 = row.string("apk_sha256"), !apkSHA256.isEmpty,
              let schemeText = row.string("signature_scheme"),
              let scheme = APKSigningIdentity.Scheme(rawValue: schemeText),
              let trustText = row.string("trust_source"),
              let trustSource = ExtensionTrustSource(persistedValue: trustText) else {
            // Rows created before signer admission are intentionally not
            // executable until they are re-admitted and populated.
            return nil
        }
        let currentSigners = stringArray(row.string("current_signers"))
        let signerHistory = stringArray(row.string("signer_history"))
        guard !currentSigners.isEmpty, !signerHistory.isEmpty else { return nil }
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
            sourceIDs: Set(int64Array(row.string("source_ids"))),
            repositoryURL: row.string("repo_url"),
            installedAt: row.int64("installed_at") ?? 0,
            enabled: row.bool("enabled")
        )
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

    private static func joinedChapter(
        from row: SQLiteDatabase.Row, id: Int64, mangaID: Int64, url: String, name: String
    ) -> Chapter {
        Chapter(
            id: id, mangaId: mangaID, sourceOrder: row.int("chapter_source_order") ?? 0,
            url: url, name: name, scanlator: row.string("chapter_scanlator"),
            number: row.double("chapter_number") ?? -1, dateUpload: row.int64("chapter_date_upload") ?? 0,
            read: row.bool("chapter_read"), bookmark: row.bool("chapter_bookmark"),
            lastPageRead: row.int("chapter_last_page_read") ?? 0
        )
    }
}

#endif
