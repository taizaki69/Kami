import Foundation
import MihonCompatKit

#if canImport(SQLite3)

/// Serialized database access. All library mutations flow through this actor.
public actor LibraryStore {
    private let db: SQLiteDatabase
    private let readingOwnerID = UUID()
    public nonisolated let downloadPolicy: DownloadPolicy

    public init(path: String, downloadPolicy: DownloadPolicy = .init()) throws {
        self.downloadPolicy = downloadPolicy
        self.db = try SQLiteDatabase(path: path)
        try Migrations.apply(db)
    }

    public init(inMemory: Bool = true, downloadPolicy: DownloadPolicy = .init()) throws {
        self.downloadPolicy = downloadPolicy
        self.db = try SQLiteDatabase(path: inMemory ? ":memory:" : ":memory:")
        try Migrations.apply(db)
    }

    /// A point-in-time archive of all persisted library domain data. This does
    /// not include installation authority, operational work or downloaded files.
    /// App callers must separately require an available durable database.
    public func exportBackupSnapshot(
        exportID: UUID = UUID(), exportedAt: Int64,
        policy: LibraryBackupPolicy = .default
    ) throws -> LibraryBackupDocument {
        do {
            return try withLibraryTransaction(readOnly: true) {
                try LibraryBackupSnapshotReader.read(
                    db, exportID: exportID, exportedAt: exportedAt, policy: policy,
                    foolSlideBinding: { try self.backupFoolSlideContentBinding() }
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LibraryBackupSnapshotError {
            throw error
        } catch let error as LibraryBackupError {
            throw error
        } catch {
            throw LibraryBackupSnapshotError.storageUnavailable
        }
    }

    /// The content namespace survives installation/settings loss. Export never
    /// infers it anew or converts it into executable preferences.
    private func backupFoolSlideContentBinding() throws -> LibraryBackupDocument.ContentBinding {
        do {
            guard let binding = try SourceContentBindingPersistence.read(db) else {
                throw LibraryBackupSnapshotError.invalidStoredData
            }
            return .init(kind: binding.kind == .deployment ? .deployment : .unresolved,
                         deploymentURL: binding.deploymentURL)
        } catch is ExtensionPreferencesError {
            throw LibraryBackupSnapshotError.invalidStoredData
        }
    }

    /// Reads immutable input and target state without changing the library.
    /// Exclusions are explicit and are part of this store-issued preview.
    public func previewLibraryRestore(
        from data: Data, excludingConflictedSources: Bool = false,
        policy: LibraryBackupPolicy = .default
    ) throws -> LibraryRestorePreview {
        let input = try LibraryBackupCodec(policy: policy).decode(data)
        return try makeRestorePreview(data: data, excludingConflictedSources: excludingConflictedSources,
            policy: policy, acknowledgesMihonLimitations: false) { _ in (input, nil) }
    }

    public func previewMihonRestore(
        from data: Data, acknowledgingLimitations: Bool = false,
        decodingPolicy: TachibkReader.Policy = .default, policy: LibraryBackupPolicy = .default
    ) throws -> LibraryRestorePreview {
        return try makeRestorePreview(data: data, excludingConflictedSources: false,
            policy: policy, acknowledgesMihonLimitations: acknowledgingLimitations) { target in
                let mapped = try MihonLibraryImport.decode(data, decodingPolicy: decodingPolicy, policy: policy, target: target)
                return (mapped.document, mapped.report)
            }
    }

    private func makeRestorePreview(data: Data, excludingConflictedSources: Bool,
                                    policy: LibraryBackupPolicy, acknowledgesMihonLimitations: Bool,
                                    prepare: (LibraryBackupDocument) throws -> (LibraryBackupDocument, MihonLibraryImportReport?)) throws -> LibraryRestorePreview {
        do {
            let stamp = try db.restoreChangeStamp()
            let preview = try withLibraryTransaction(readOnly: true) {
                let state = try LibraryRestorePersistence.state(db, policy: policy)
                let (input, mihonReport) = try prepare(state.document)
                let plan = try LibraryRestorePlanner.plan(input: input, target: state.document,
                    foolSlideBinding: state.binding, policy: policy)
                try Task.checkCancellation()
                return LibraryRestorePreview(id: UUID(), inputSHA256: APKSignatureVerifier.apkSHA256(Array(data)),
                    summary: plan.summary, conflicts: plan.conflicts, excludesConflictedSources: excludingConflictedSources,
                    sources: input.sources, mihonReport: mihonReport, acknowledgesMihonLimitations: acknowledgesMihonLimitations,
                    ownerID: readingOwnerID, epoch: state.epoch,
                    dependencyDigest: state.digest, changeStamp: stamp, policy: policy, plan: plan)
            }
            // A WAL writer may commit while our read snapshot is open. Never
            // associate that newer data_version with an older approved snapshot.
            guard try db.restoreChangeStamp() == stamp else { throw LibraryRestoreError.previewExpired }
            try Task.checkCancellation()
            return preview
        } catch is SQLiteDatabase.SQLiteError { throw LibraryRestoreError.storageUnavailable }
        catch is ReadingStateError { throw LibraryRestoreError.invalidStoredData }
        catch is ExtensionPreferencesError { throw LibraryRestoreError.invalidStoredData }
    }

    /// The app must hold its shared exclusive operation scope for this call.
    /// Database revalidation also guards other connections and durable workers.
    public func commitLibraryRestore(_ preview: LibraryRestorePreview) throws -> LibraryRestoreReport {
        try Task.checkCancellation()
        guard preview.ownerID == readingOwnerID else { throw LibraryRestoreError.foreignPreview }
        if let reason = preview.restoreBlockReason { throw reason }
        do {
            return try withLibraryTransaction {
                try LibraryRestorePersistence.requireIdle(db)
                guard try db.restoreChangeStamp() == preview.changeStamp,
                      try ReadingStateReader.epoch(db) == preview.epoch else { throw LibraryRestoreError.previewExpired }
                let current = try LibraryRestorePersistence.state(db, policy: preview.policy)
                guard current.digest == preview.dependencyDigest else { throw LibraryRestoreError.previewExpired }
                try LibraryRestorePersistence.write(db, plan: preview.plan)
                try Task.checkCancellation()
                try db.run("UPDATE library_data_state SET epoch=randomblob(16) WHERE singleton=1")
                guard try ReadingStateReader.epoch(db) != preview.epoch else { throw LibraryRestoreError.storageUnavailable }
                try Task.checkCancellation()
                return LibraryRestoreReport(previewID: preview.id, summary: preview.summary)
            }
        } catch is SQLiteDatabase.SQLiteError { throw LibraryRestoreError.storageUnavailable }
        catch is ReadingStateError { throw LibraryRestoreError.invalidStoredData }
        catch is ExtensionPreferencesError { throw LibraryRestoreError.invalidStoredData }
        catch is LibraryBackupError { throw LibraryRestoreError.invalidStoredData }
        catch is LibraryBackupSnapshotError { throw LibraryRestoreError.invalidStoredData }
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
    func upsert(_ manga: Manga, inLibrary: Bool? = nil) throws -> Int64 {
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

    public func setLibrary(_ inLibrary: Bool, mangaId: Int64, context: LibraryMutationContext) throws {
        try withLibraryMutation(context) {
            try db.run("UPDATE manga SET in_library=? WHERE id=?", [.bool(inLibrary), .int(mangaId)])
            if !inLibrary {
                _ = try invalidateDownloadsInTransaction(where: "manga_id=?", values: [.int(mangaId)],
                                                          reason: .mangaRemoved)
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
                                   categoryIDsByManga: membership, mutationContext: try currentMutationContext())
        }
    }

    @discardableResult
    public func createCategory(name: String, context: LibraryMutationContext) throws -> Category {
        let name = try Category.validatedName(name)
        return try withLibraryMutation(context) {
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

    public func renameCategory(id: Int64, name: String, context: LibraryMutationContext) throws {
        let name = try Category.validatedName(name)
        try withLibraryMutation(context) {
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

    public func reorderCategories(ids: [Int64], context: LibraryMutationContext) throws {
        try withLibraryMutation(context) {
            try Category.validateOrder(ids, existingIDs: Set(try categories().compactMap(\.id)))
            try persistCategoryOrder(ids)
        }
    }

    /// Foreign-key cascading removes only the category's associations.
    /// Manga rows, chapter state, and history are never deleted here.
    public func deleteCategories(ids: Set<Int64>, context: LibraryMutationContext) throws {
        try withLibraryMutation(context) {
            guard !ids.isEmpty else { return }
            let existing = try categories()
            try validateCategoryIDs(ids, categories: existing)
            for id in ids.sorted() {
                try db.run("DELETE FROM category WHERE id=?", [.int(id)])
            }
            try persistCategoryOrder(existing.compactMap(\.id).filter { !ids.contains($0) })
        }
    }

    public func setCategories(_ categoryIDs: Set<Int64>, mangaId: Int64, context: LibraryMutationContext) throws {
        try setCategories(categoryIDs, mangaIDs: [mangaId], context: context)
    }

    /// Replaces membership atomically after validating every manga and category.
    public func setCategories(_ categoryIDs: Set<Int64>, mangaIDs: Set<Int64>, context: LibraryMutationContext) throws {
        try withLibraryMutation(context) {
            guard !mangaIDs.isEmpty else { return }
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
        mangaIDs: Set<Int64>,
        context: LibraryMutationContext
    ) throws {
        guard adding.isDisjoint(with: removing) else {
            throw LibraryCategoryError.conflictingCategoryChanges
        }
        try withLibraryMutation(context) {
            guard !mangaIDs.isEmpty else { return }
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

    private func currentMutationContext() throws -> LibraryMutationContext {
        do {
            return .init(ownerID: readingOwnerID, epoch: try ReadingStateReader.epoch(db))
        } catch is CancellationError { throw CancellationError() }
        catch is SQLiteDatabase.SQLiteError { throw LibraryMutationError.storageUnavailable }
        catch { throw LibraryMutationError.invalidStoredState }
    }

    private func validateMutationContext(_ context: LibraryMutationContext) throws {
        try Task.checkCancellation()
        guard context.ownerID == readingOwnerID else { throw LibraryMutationError.foreignContext }
        guard try currentMutationContext().epoch == context.epoch else { throw LibraryMutationError.staleEpoch }
    }

    private func withLibraryMutation<T>(
        _ context: LibraryMutationContext, _ operation: () throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        do {
            return try withLibraryTransaction {
                try validateMutationContext(context)
                let result = try operation()
                try Task.checkCancellation()
                return result
            }
        } catch is SQLiteDatabase.SQLiteError { throw LibraryMutationError.storageUnavailable }
    }

    /// Initial source opening captures stored values and the data generation
    /// together. After suspension, pass the original context to reject rebasing.
    public func sourceMangaSnapshot(
        sourceID: Int64, mangaURL: String, validating context: LibraryMutationContext? = nil
    ) throws -> SourceMangaSnapshot {
        try Task.checkCancellation()
        return try withLibraryTransaction(readOnly: true) {
            if let context { try validateMutationContext(context) }
            try ReadingStateReader.validateInputURL(mangaURL)
            let captured = try currentMutationContext()
            let id = try ReadingStateReader.mangaID(db, sourceID: sourceID, url: mangaURL)
            let reading = try id.map {
                try ReadingStateReader.snapshot(db, ownerID: readingOwnerID, epoch: captured.epoch,
                                                mangaID: $0, requestedChapterID: nil)
            }
            try Task.checkCancellation()
            return SourceMangaSnapshot(reading: reading, mutationContext: captured)
        }
    }

    public func sourceMangaSnapshot(
        mangaID: Int64, validating context: LibraryMutationContext
    ) throws -> SourceMangaSnapshot {
        try Task.checkCancellation()
        return try withLibraryTransaction(readOnly: true) {
            try validateMutationContext(context)
            let exists = try !db.query("SELECT 1 FROM manga WHERE id=? LIMIT 1", [.int(mangaID)]).isEmpty
            let reading = exists ? try ReadingStateReader.snapshot(
                db, ownerID: readingOwnerID, epoch: context.epoch, mangaID: mangaID, requestedChapterID: nil) : nil
            try Task.checkCancellation()
            return SourceMangaSnapshot(reading: reading, mutationContext: context)
        }
    }

    // MARK: - Chapters

    public func chapters(mangaId: Int64) throws -> [Chapter] {
        try db.query("SELECT * FROM chapter WHERE manga_id=? AND is_current=1 ORDER BY source_order", [.int(mangaId)])
            .compactMap(Self.chapter(from:))
    }

    func replaceChapters(mangaId: Int64, with chapters: [Chapter]) throws {
        try withLibraryTransaction {
            try replaceChaptersInTransaction(mangaId: mangaId, with: chapters)
            try establishInitialChapterBaseline(mangaId: mangaId)
        }
    }

    private func replaceChaptersInTransaction(mangaId: Int64, with chapters: [Chapter]) throws {
        let existing = try db.query(
            "SELECT id, CAST(url AS BLOB) AS url_bytes FROM chapter WHERE manga_id=?", [.int(mangaId)]
        )
        // SQLite uses byte identity for these keys. Swift String equality
        // would merge distinct composed/decomposed URL spellings.
        var idsByURL: [Data: Int64] = [:]
        for row in existing {
            if let id = row.int64("id"), let url = row.bytes("url_bytes") {
                idsByURL[Data(url)] = id
            }
        }

        // A source may repeat a URL. Preserve its first metadata/order and
        // never write or count the same discovery twice.
        var acceptedURLs: Set<Data> = []
        let unique = chapters.filter { acceptedURLs.insert(Data($0.url.utf8)).inserted }
        for (order, ch) in unique.enumerated() {
            if let id = idsByURL[Data(ch.url.utf8)] {
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

        let incomingURLs = Set(unique.map { Data($0.url.utf8) })
        for row in existing {
            guard let id = row.int64("id"),
                  let url = row.bytes("url_bytes"),
                  !incomingURLs.contains(Data(url)) else { continue }
            // Keep reading state and history if the URL later reappears.
            try db.run("UPDATE chapter SET is_current=0 WHERE id=?", [.int(id)])
        }
        _ = try invalidateDownloadsInTransaction(
            where: "manga_id=? AND chapter_id IN (SELECT id FROM chapter WHERE is_current=0)",
            values: [.int(mangaId)], reason: .chapterUnavailable)
    }

    /// The source/configuration check and every source-result write share the
    /// transaction. An obsolete runtime cannot insert a relative manga URL
    /// after a deployment change, even if its network result arrived later.
    public func persistSourceUpdate(
        manga: Manga,
        chapters: [SChapterCompat],
        expectedConfiguration: ExtensionExecutionConfiguration?,
        context: LibraryMutationContext
    ) throws -> SourceMangaUpdate {
        try Task.checkCancellation()
        return try withLibraryMutation(context) {
            try verifySourceUpdateConfiguration(sourceID: manga.sourceId, expectedConfiguration: expectedConfiguration)
            if let id = manga.id {
                guard let stored = try self.manga(id: id),
                      stored.sourceId == manga.sourceId, Data(stored.url.utf8) == Data(manga.url.utf8) else {
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

    /// Check captured configuration before requesting source content. The
    /// transactional result check remains necessary after asynchronous work.
    public func validateSourceExecution(
        sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?,
        context: LibraryMutationContext
    ) throws {
        try Task.checkCancellation()
        try withLibraryTransaction(readOnly: true) {
            try validateMutationContext(context)
            try verifySourceUpdateConfiguration(sourceID: sourceID, expectedConfiguration: expectedConfiguration)
            try Task.checkCancellation()
        }
    }

    private func verifySourceUpdateConfiguration(
        sourceID: Int64,
        expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws {
        if let expectedConfiguration {
            try verifyExtensionExecutionConfigurationInTransaction(expectedConfiguration)
            guard expectedConfiguration.installed.sourceIDs.contains(sourceID) else {
                throw SourceUpdatePersistenceError.sourceIdentityMismatch
            }
        } else {
            // Downloaded profiles cannot use nil to bypass their CAS token.
            guard sourceID == MangaDexSource().id else {
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
        let known = Set(try db.query("SELECT CAST(url AS BLOB) AS url_bytes FROM known_chapter WHERE manga_id=?", [.int(mangaId)])
            .compactMap { $0.bytes("url_bytes").map { Data($0) } })
        var seen: Set<Data> = []
        let unseen = urls.filter {
            let key = Data($0.utf8)
            return seen.insert(key).inserted && !known.contains(key)
        }
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
            return LibraryUpdateScanSnapshot(record: try readLibraryUpdateSummary(scanID), items: items,
                                             mutationContext: try currentMutationContext())
        }
    }

    public func recordLibraryUpdateSuccess(
        scanID: UUID,
        manga: Manga,
        chapters: [SChapterCompat],
        expectedConfiguration: ExtensionExecutionConfiguration?,
        context: LibraryMutationContext
    ) throws -> LibraryUpdateCommitResult {
        try Task.checkCancellation()
        return try withLibraryMutation(context) {
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
                  stored.sourceId == manga.sourceId, Data(stored.url.utf8) == Data(manga.url.utf8) else {
                throw LibraryUpdatePersistenceError.sourceIdentityMismatch
            }
            try verifySourceUpdateConfiguration(sourceID: manga.sourceId, expectedConfiguration: expectedConfiguration)
            var seen: Set<Data> = []
            let unique = chapters.filter { seen.insert(Data($0.url.utf8)).inserted }
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

    // MARK: - Guarded reading state

    /// Explicit initial opening by exact source/UTF-8 manga identity. Retained
    /// sessions must validate their captured target instead of calling this to
    /// obtain the latest epoch after a provider suspension.
    public func readingSnapshot(
        sourceID: Int64, mangaURL: String, requestedChapterID: Int64? = nil
    ) throws -> MangaReadingSnapshot? {
        try readingOperation(readOnly: true) {
            try ReadingStateReader.validateInputURL(mangaURL)
            let epoch = try ReadingStateReader.epoch(db)
            guard let id = try ReadingStateReader.mangaID(db, sourceID: sourceID, url: mangaURL) else { return nil }
            return try ReadingStateReader.snapshot(db, ownerID: readingOwnerID, epoch: epoch,
                                                   mangaID: id, requestedChapterID: requestedChapterID)
        }
    }

    /// Refreshes metadata/lists only after validating the retained target. This
    /// cannot rebase an old session onto a new epoch or a rebound physical row.
    public func refreshReadingSnapshot(validating target: ChapterWriteTarget) throws -> MangaReadingSnapshot {
        try readingOperation(readOnly: true) {
            _ = try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
            return try ReadingStateReader.snapshot(db, ownerID: readingOwnerID, epoch: target.epoch,
                                                   mangaID: target.mangaID, requestedChapterID: target.chapterID)
        }
    }

    /// Returns fresh stored chapter state without minting a replacement target.
    public func validateReadingTarget(_ target: ChapterWriteTarget) throws -> Chapter {
        try readingOperation(readOnly: true) {
            try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
        }
    }

    /// Atomically saves page/read/history. Backwards page navigation is valid;
    /// reaching the end sets read, while other progress preserves its value.
    /// The existing bookmark and history duration are never cleared.
    @discardableResult
    public func commitReadingProgress(
        target: ChapterWriteTarget, page: Int64, reachedEnd: Bool, lastRead: Int64
    ) throws -> ReadingProgressResult {
        try Task.checkCancellation()
        guard page >= 0, Int(exactly: page) != nil, lastRead >= 0 else { throw ReadingStateError.invalidInput }
        return try readingOperation {
            _ = try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
            _ = try ReadingStateReader.history(db, target: target)
            try db.run("UPDATE chapter SET last_page_read=?,read=CASE WHEN ? THEN 1 ELSE read END WHERE id=?",
                       [.int(page), .bool(reachedEnd), .int(target.chapterID)])
            try db.run("""
                INSERT INTO history(manga_id,chapter_id,last_read,read_duration) VALUES (?,?,?,0)
                ON CONFLICT(manga_id,chapter_id) DO UPDATE SET last_read=excluded.last_read
                """, [.int(target.mangaID), .int(target.chapterID), .int(lastRead)])
            let chapter = try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
            guard let history = try ReadingStateReader.history(db, target: target) else {
                throw ReadingStateError.invalidStoredData
            }
            return ReadingProgressResult(chapter: chapter, lastRead: history.lastRead,
                                         readDuration: history.duration)
        }
    }

    /// A manual read toggle changes only the captured row's read flag.
    @discardableResult
    public func setChapterRead(_ read: Bool, target: ChapterWriteTarget) throws -> Chapter {
        try readingOperation {
            _ = try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
            try db.run("UPDATE chapter SET read=? WHERE id=?", [.bool(read), .int(target.chapterID)])
            return try ReadingStateReader.validate(db, ownerID: readingOwnerID, target: target)
        }
    }

    private func readingOperation<T>(readOnly: Bool = false, _ operation: () throws -> T) throws -> T {
        do {
            try Task.checkCancellation()
            return try withLibraryTransaction(readOnly: readOnly) {
                try Task.checkCancellation()
                let result = try operation()
                // A cancellation here rolls back. There is deliberately no
                // cancellation check after COMMIT reports successful persistence.
                try Task.checkCancellation()
                return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReadingStateError { throw error }
        catch { throw ReadingStateError.storageUnavailable }
    }

    // MARK: - History

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
        try withLibraryTransaction {
            if let previous = try installedExtensionTrust(packageName: packageName),
               previous.enabled != enabled {
                _ = try invalidateDownloadSourceIDsInTransaction(previous.sourceIDs)
            }
            try db.run(
                "UPDATE installed_extension SET enabled=? WHERE package_name=?",
                [.bool(enabled), .text(packageName)]
            )
        }
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
        // Re-admission can replace an identical runtime in the same second.
        // Revoke attempts even when the exact release/configuration is equal.
        _ = try invalidateDownloadSourceIDsInTransaction(
            candidate.sourceIDs.union(existing?.sourceIDs ?? []))
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
        let binding = SourceContentBindingPersistence.supports(schema)
            ? try SourceContentBindingPersistence.read(db) : nil
        return try ExtensionConfigurationReader.read(db, installed: installed, schema: schema, contentBinding: binding)
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
                  previous.matches(userValues: snapshot.userValues) else {
                throw ExtensionPreferencesError.staleConfiguration
            }
            guard SourceContentBindingPersistence.supports(snapshot.schema) else {
                throw ExtensionPreferencesError.unsupportedProfile
            }
            guard snapshot.revision < Int64.max else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            let binding = try SourceContentBindingPersistence.save(
                db, expected: snapshot.contentBinding, url: resolved.baseURL)
            _ = try invalidateDownloadSourceIDsInTransaction(snapshot.schema.identity.sourceIDs)
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
                revision: revision, contentBinding: binding
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
        if configuration.installed.sourceIDs.contains(SourceContentBindingPersistence.sourceID), configuration.snapshot == nil {
            throw ExtensionPreferencesError.configurationRequired
        }
        if let expected = configuration.snapshot {
            let current = try readExtensionConfiguration(installed: configuration.installed, schema: expected.schema)
            guard current == expected else { throw ExtensionPreferencesError.staleConfiguration }
            try SourceContentBindingPersistence.requireExecution(current)
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

    static func installedExtensionTrust(
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

// Download identities refer to generated content. Authentication and execution
// configuration remain in nonserializable tokens checked inside each mutation.
extension LibraryStore {
    private static let downloadJoin = """
        SELECT m.*, c.id AS chapter_id, c.url AS chapter_url, c.name AS chapter_name,
            c.source_order AS chapter_source_order, c.scanlator AS chapter_scanlator,
            c.number AS chapter_number, c.date_upload AS chapter_date_upload,
            c.read AS chapter_read, c.bookmark AS chapter_bookmark,
            c.last_page_read AS chapter_last_page_read, c.is_current AS chapter_is_current
        FROM chapter c JOIN manga m ON m.id=c.manga_id
        """

    private static let downloadItemJoin = """
        SELECT m.*, c.id AS chapter_id, c.url AS chapter_url, c.name AS chapter_name,
            c.source_order AS chapter_source_order, c.scanlator AS chapter_scanlator,
            c.number AS chapter_number, c.date_upload AS chapter_date_upload,
            c.read AS chapter_read, c.bookmark AS chapter_bookmark,
            c.last_page_read AS chapter_last_page_read, c.is_current AS chapter_is_current,
            j.job_id, j.manga_id AS captured_manga_id, j.source_id AS captured_source_id,
            j.manga_url_digest, j.chapter_url_digest, j.state, j.revision, j.attempt_id,
            j.page_count, j.completed_pages, j.stored_bytes, j.reason,
            j.manifest_sha256, j.queue_order, j.created_at, j.updated_at
        FROM download_job j JOIN chapter c ON c.id=j.chapter_id
        JOIN manga m ON m.id=c.manga_id
        """

    public func downloadTarget(chapterID: Int64) throws -> DownloadTarget {
        guard let row = try db.query(Self.downloadJoin + " WHERE c.id=? LIMIT 1", [.int(chapterID)]).first else {
            throw DownloadPersistenceError.chapterNotFound
        }
        return try Self.downloadTarget(from: row)
    }

    public func downloadItem(jobID: UUID) throws -> DownloadItem? {
        try db.query(Self.downloadItemJoin + " WHERE j.job_id=? LIMIT 1", [.text(jobID.uuidString)])
            .first.map(Self.downloadItem(from:))
    }

    public func nextQueuedDownload() throws -> DownloadItem? {
        try db.query(Self.downloadItemJoin + " WHERE j.state=0 ORDER BY j.queue_order,j.job_id LIMIT 1")
            .first.map(Self.downloadItem(from:))
    }

    public func downloadsSnapshot(
        limit: Int = 100, after: DownloadQueueCursor? = nil
    ) throws -> DownloadQueueSnapshot {
        try withLibraryTransaction(readOnly: true) {
            let count = max(1, min(500, limit))
            var sql = Self.downloadItemJoin
            var values: [SQLiteBindable] = []
            if let after {
                sql += " WHERE (j.queue_order>? OR (j.queue_order=? AND j.job_id>?))"
                values = [.int(after.queueOrder), .int(after.queueOrder), .text(after.jobID.uuidString)]
            }
            sql += " ORDER BY j.queue_order,j.job_id LIMIT ?"
            values.append(.int(count + 1))
            let rows = try db.query(sql, values)
            let hasMore = rows.count > count
            let items = try rows.prefix(count).map(Self.downloadItem(from:))
            let cursor = hasMore ? items.last.map {
                DownloadQueueCursor(queueOrder: $0.queueOrder, jobID: $0.jobID)
            } : nil
            return DownloadQueueSnapshot(items: items, summary: try downloadQueueSummary(),
                                         hasMore: hasMore, nextCursor: cursor)
        }
    }

    public func downloadChapterStates(mangaID: Int64) throws -> [Int64: DownloadChapterState] {
        try downloadChapterStateRows(where: "manga_id=?", values: [.int(mangaID)])
    }

    public func downloadChapterStates(chapterIDs: [Int64]) throws -> [Int64: DownloadChapterState] {
        guard chapterIDs.count <= 500 else { throw DownloadPersistenceError.selectionTooLarge }
        let ids = Set(chapterIDs).sorted()
        guard !ids.isEmpty else { return [:] }
        return try downloadChapterStateRows(
            where: "chapter_id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")",
            values: ids.map(SQLiteBindable.int))
    }

    public func downloadedChapterCountsByManga() throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for row in try db.query("""
            SELECT j.manga_id,COUNT(*) AS count FROM download_job j
            JOIN manga m ON m.id=j.manga_id WHERE j.state=2 AND m.in_library=1
            GROUP BY j.manga_id
            """) {
            if let id = row.int64("manga_id"), let count = row.int("count") { result[id] = count }
        }
        return result
    }

    public func downloadedChapters(mangaID: Int64) throws -> [Chapter] {
        try db.query("""
            SELECT c.* FROM chapter c JOIN download_job j ON j.chapter_id=c.id
            WHERE j.state=2 AND j.manga_id=? ORDER BY c.source_order,c.id
            """, [.int(mangaID)]).compactMap(Self.chapter(from:))
    }

    public func pendingDownloadCleanup() throws -> [DownloadContentIdentity] {
        try db.query("SELECT * FROM download_cleanup ORDER BY attempt_id")
            .map(Self.cleanupIdentity(from:))
    }

    public func completedDownloadIdentities() throws -> [DownloadContentIdentity] {
        try db.query(Self.downloadItemJoin + " WHERE j.state=2 ORDER BY j.queue_order,j.job_id")
            .map { row in
                guard let identity = try Self.downloadItem(from: row).contentIdentity else {
                    throw DownloadPersistenceError.invalidStoredRecord
                }
                return identity
            }
    }

    /// Merely queues a target. Callers obtain a current source separately and
    /// explicitly start transfer; persisting a row never enables an extension.
    public func enqueueDownload(
        chapterID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> DownloadItem {
        try withDownloadTransaction {
            let target = try validatedDownloadTarget(chapterID: chapterID, expectedConfiguration: expectedConfiguration)
            if let row = try db.query("SELECT job_id FROM download_job WHERE chapter_id=?", [.int(chapterID)]).first,
               let text = row.string("job_id"), let id = UUID(uuidString: text) {
                let existing = try requiredDownloadItem(id)
                try verifyDownloadIdentity(existing, target: target)
                return existing
            }
            guard (try db.query("SELECT COUNT(*) AS count FROM download_job").first?.int("count") ?? 0)
                    < downloadPolicy.maximumJobs else { throw DownloadPersistenceError.queueLimitExceeded }
            let jobID = UUID()
            let now = Self.downloadNow()
            let order = try nextDownloadQueueOrder()
            let origin = try downloadOrigin(expectedConfiguration)
            try db.run("""
                INSERT INTO download_job(
                    job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,state,
                    revision,library_revision,origin_package,origin_fingerprint,configuration_revision,
                    queue_order,created_at,updated_at
                ) VALUES (?,?,?,?,?,?,0,1,?,?,?,?,?,?,?)
                """, [.text(jobID.uuidString), .int(chapterID), .int(target.manga.id!),
                      .int(target.manga.sourceId), .text(Self.downloadDigest(target.manga.url)),
                      .text(Self.downloadDigest(target.chapter.url)), .int(try downloadLibraryRevision(target.manga.id!)),
                      origin.package, origin.fingerprint, origin.revision, .int(order), .int(now), .int(now)])
            return try requiredDownloadItem(jobID)
        }
    }

    public func retryDownload(
        jobID: UUID, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> DownloadItem {
        try withDownloadTransaction {
            let previous = try requiredDownloadItem(jobID)
            let target = try validatedDownloadTarget(chapterID: previous.chapter.id!, expectedConfiguration: expectedConfiguration)
            try verifyDownloadIdentity(previous, target: target, allowLegacy: true)
            if previous.state == .queued { return previous }
            guard [.paused, .failed, .cancelled].contains(previous.state) else {
                throw DownloadPersistenceError.invalidState
            }
            guard try db.query("SELECT 1 FROM download_cleanup WHERE job_id=? LIMIT 1",
                               [.text(jobID.uuidString)]).isEmpty else { throw DownloadPersistenceError.cleanupPending }
            guard previous.contentIdentity == nil else { throw DownloadPersistenceError.cleanupPending }
            let origin = try downloadOrigin(expectedConfiguration)
            try db.run("""
                UPDATE download_job SET state=0,revision=?,reason=NULL,library_revision=?,
                    manga_url_digest=?,chapter_url_digest=?,origin_package=?,origin_fingerprint=?,
                    configuration_revision=?,queue_order=?,updated_at=?
                WHERE job_id=?
                """, [.int(try nextDownloadRevision(previous.revision)),
                      .int(try downloadLibraryRevision(target.manga.id!)),
                      .text(Self.downloadDigest(target.manga.url)), .text(Self.downloadDigest(target.chapter.url)),
                      origin.package, origin.fingerprint, origin.revision,
                      .int(try nextDownloadQueueOrder()), .int(Self.downloadNow()), .text(jobID.uuidString)])
            return try requiredDownloadItem(jobID)
        }
    }

    public func beginDownloadAttempt(
        jobID: UUID, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> DownloadAttempt {
        try withDownloadTransaction {
            let previous = try requiredDownloadItem(jobID)
            guard previous.state == .queued else { throw DownloadPersistenceError.invalidState }
            guard try db.query("SELECT 1 FROM download_job WHERE state=1 LIMIT 1").isEmpty else {
                throw DownloadPersistenceError.activeAttemptExists
            }
            guard previous.contentIdentity == nil,
                  try db.query("SELECT 1 FROM download_cleanup WHERE job_id=? LIMIT 1",
                               [.text(jobID.uuidString)]).isEmpty else { throw DownloadPersistenceError.cleanupPending }
            let target = try validatedDownloadTarget(chapterID: previous.chapter.id!, expectedConfiguration: expectedConfiguration)
            try verifyDownloadIdentity(previous, target: target)
            try verifyQueuedDownloadOrigin(jobID: jobID, expectedConfiguration: expectedConfiguration)
            let revision = try nextDownloadRevision(previous.revision)
            let libraryRevision = try downloadLibraryRevision(target.manga.id!)
            let identity = DownloadContentIdentity(
                jobID: jobID, attemptID: UUID(), mangaID: target.manga.id!, chapterID: target.chapter.id!,
                sourceID: target.manga.sourceId, mangaURLDigest: Self.downloadDigest(target.manga.url),
                chapterURLDigest: Self.downloadDigest(target.chapter.url))
            try db.run("""
                UPDATE download_job SET state=1,revision=?,attempt_id=?,library_revision=?,
                    publication_state='working',reason=NULL,updated_at=? WHERE job_id=?
                """, [.int(revision), .text(identity.attemptID.uuidString), .int(libraryRevision),
                      .int(Self.downloadNow()), .text(jobID.uuidString)])
            return DownloadAttempt(identity: identity, revision: revision, manga: target.manga,
                                   chapter: target.chapter, policy: downloadPolicy,
                                   libraryRevision: libraryRevision, expectedConfiguration: expectedConfiguration)
        }
    }
}

extension LibraryStore {
    public func setDownloadPageCount(attempt: DownloadAttempt, pageCount: Int) throws -> DownloadItem {
        guard pageCount > 0, pageCount <= downloadPolicy.maximumPageCount else {
            throw DownloadPersistenceError.pageLimitExceeded
        }
        return try withDownloadTransaction {
            let item = try verifyDownloadAttempt(attempt)
            try requireWorkingDownload(attempt.jobID)
            if let previous = item.pageCount {
                guard previous == pageCount else { throw DownloadPersistenceError.invalidState }
                return item
            }
            try db.run("UPDATE download_job SET page_count=?,updated_at=? WHERE job_id=?",
                       [.int(pageCount), .int(Self.downloadNow()), .text(attempt.jobID.uuidString)])
            return try requiredDownloadItem(attempt.jobID)
        }
    }

    /// Identical receipt retries are idempotent. A changed digest/size at an
    /// existing ordinal cannot replace committed bytes in the same attempt.
    public func commitDownloadPage(
        attempt: DownloadAttempt, receipt: DownloadPageReceipt
    ) throws -> DownloadItem {
        try Self.validateDownloadReceipt(receipt, policy: downloadPolicy)
        return try withDownloadTransaction {
            let item = try verifyDownloadAttempt(attempt)
            try requireWorkingDownload(attempt.jobID)
            guard let count = item.pageCount, receipt.ordinal < count else {
                throw DownloadPersistenceError.invalidReceipt
            }
            let pages = try downloadPages(identity: attempt.identity)
            if let previous = pages.first(where: { $0.ordinal == receipt.ordinal }) {
                guard previous == receipt else { throw DownloadPersistenceError.invalidReceipt }
                return item
            }
            let (total, overflow) = item.storedBytes.addingReportingOverflow(receipt.byteCount)
            guard !overflow, total <= downloadPolicy.maximumChapterBytes else {
                throw DownloadPersistenceError.chapterLimitExceeded
            }
            try db.run("""
                INSERT INTO download_page(job_id,attempt_id,ordinal,byte_count,sha256) VALUES (?,?,?,?,?)
                """, [.text(attempt.jobID.uuidString), .text(attempt.attemptID.uuidString),
                      .int(receipt.ordinal), .int(receipt.byteCount), .text(receipt.sha256)])
            try db.run("""
                UPDATE download_job SET completed_pages=completed_pages+1,stored_bytes=?,updated_at=? WHERE job_id=?
                """, [.int(total), .int(Self.downloadNow()), .text(attempt.jobID.uuidString)])
            return try requiredDownloadItem(attempt.jobID)
        }
    }

    public func prepareDownload(
        attempt: DownloadAttempt, manifestReceipt: DownloadManifestReceipt
    ) throws -> DownloadItem {
        try withDownloadTransaction {
            let item = try verifyDownloadAttempt(attempt)
            try verifyDownloadManifest(item: item, identity: attempt.identity, receipt: manifestReceipt)
            let phase = try downloadPublicationPhase(attempt.jobID)
            guard phase == "working" || phase == "prepared" else { throw DownloadPersistenceError.invalidState }
            if phase == "prepared" {
                guard item.manifestSHA256 == manifestReceipt.manifestSHA256 else {
                    throw DownloadPersistenceError.manifestMismatch
                }
                return item
            }
            try db.run("""
                UPDATE download_job SET publication_state='prepared',manifest_sha256=?,updated_at=? WHERE job_id=?
                """, [.text(manifestReceipt.manifestSHA256), .int(Self.downloadNow()), .text(attempt.jobID.uuidString)])
            return try requiredDownloadItem(attempt.jobID)
        }
    }

    /// Publication is authoritative only after this CAS. A renamed directory
    /// whose attempt was cancelled remains cleanup work, never offline data.
    public func completeDownload(
        attempt: DownloadAttempt, manifestReceipt: DownloadManifestReceipt
    ) throws -> DownloadItem {
        try withDownloadTransaction {
            let current = try requiredDownloadItem(attempt.jobID)
            if current.state == .finished, current.contentIdentity == attempt.identity,
               current.revision == attempt.revision {
                try verifyDownloadManifest(item: current, identity: attempt.identity, receipt: manifestReceipt)
                guard current.manifestSHA256 == manifestReceipt.manifestSHA256 else {
                    throw DownloadPersistenceError.manifestMismatch
                }
                return current
            }
            let item = try verifyDownloadAttempt(attempt)
            guard try downloadPublicationPhase(attempt.jobID) == "prepared",
                  item.manifestSHA256 == manifestReceipt.manifestSHA256 else {
                throw DownloadPersistenceError.manifestMismatch
            }
            try verifyDownloadManifest(item: item, identity: attempt.identity, receipt: manifestReceipt)
            try db.run("""
                UPDATE download_job SET state=2,publication_state='complete',reason=NULL,updated_at=? WHERE job_id=?
                """, [.int(Self.downloadNow()), .text(attempt.jobID.uuidString)])
            return try requiredDownloadItem(attempt.jobID)
        }
    }

    /// No source or admission is consulted. Filesystem validation remains the
    /// caller's next step; this only returns a sealed database generation.
    public func offlineChapter(chapterID: Int64) throws -> CompletedDownloadBundle? {
        try withLibraryTransaction(readOnly: true) {
            guard let row = try db.query(Self.downloadItemJoin + " WHERE j.chapter_id=? AND j.state=2 LIMIT 1",
                                        [.int(chapterID)]).first else { return nil }
            let item = try Self.downloadItem(from: row)
            guard let identity = item.contentIdentity, let digest = item.manifestSHA256,
                  Self.validDownloadDigest(digest),
                  try downloadPublicationPhase(item.jobID) == "complete" else {
                throw DownloadPersistenceError.invalidStoredRecord
            }
            let pages = try downloadPages(identity: identity)
            try verifyCompleteDownloadPages(item: item, pages: pages)
            return CompletedDownloadBundle(identity: identity, manifestSHA256: digest, pages: pages,
                                           totalBytes: item.storedBytes, manga: item.manga,
                                           chapter: item.chapter, isCurrentChapter: item.isCurrentChapter)
        }
    }

    public func pauseDownload(jobID: UUID) throws -> DownloadMutation {
        try withLibraryTransaction { try stopDownloadInTransaction(jobID: jobID, state: .paused, reason: .paused) }
    }

    public func cancelDownload(jobID: UUID) throws -> DownloadMutation {
        try withLibraryTransaction { try stopDownloadInTransaction(jobID: jobID, state: .cancelled, reason: .cancelled) }
    }

    public func failDownload(attempt: DownloadAttempt, reason: DownloadFailureReason) throws -> DownloadMutation {
        try withLibraryTransaction {
            let item = try requiredDownloadItem(attempt.jobID)
            // Failure reporting may follow a source disable. It cannot revive
            // or relabel the terminal generation installed by that mutation.
            guard item.state == .downloading, item.revision == attempt.revision,
                  item.contentIdentity == attempt.identity else { throw DownloadPersistenceError.staleAttempt }
            return try stopDownloadInTransaction(jobID: attempt.jobID, state: .failed, reason: reason)
        }
    }

    public func failQueuedDownload(
        jobID: UUID, expectedRevision: Int64, reason: DownloadFailureReason
    ) throws -> DownloadMutation {
        try withLibraryTransaction {
            let item = try requiredDownloadItem(jobID)
            guard item.state == .queued, item.revision == expectedRevision else {
                throw DownloadPersistenceError.staleAttempt
            }
            return try stopDownloadInTransaction(jobID: jobID, state: .failed, reason: reason)
        }
    }

    public func deleteDownload(jobID: UUID) throws -> DownloadMutation {
        try withLibraryTransaction {
            guard let item = try downloadItem(jobID: jobID) else { return DownloadMutation(item: nil, cleanup: []) }
            if item.state == .deleting {
                return DownloadMutation(item: item, cleanup: try downloadCleanup(jobID: jobID))
            }
            if item.contentIdentity == nil {
                guard try downloadCleanup(jobID: jobID).isEmpty else { throw DownloadPersistenceError.cleanupPending }
                try db.run("DELETE FROM download_job WHERE job_id=?", [.text(jobID.uuidString)])
                return DownloadMutation(item: nil, cleanup: [])
            }
            return try stopDownloadInTransaction(jobID: jobID, state: .deleting, reason: nil, allowFinished: true)
        }
    }

    public func recoverInterruptedDownloads() throws -> DownloadRecovery {
        try withLibraryTransaction {
            let jobs = try db.query("SELECT job_id FROM download_job WHERE state=1 ORDER BY queue_order,job_id")
            for row in jobs {
                guard let text = row.string("job_id"), let id = UUID(uuidString: text) else {
                    throw DownloadPersistenceError.invalidStoredRecord
                }
                _ = try stopDownloadInTransaction(jobID: id, state: .paused, reason: .interrupted)
            }
            return DownloadRecovery(interruptedJobs: jobs.count, cleanup: try pendingDownloadCleanup())
        }
    }

    public func acknowledgeDownloadCleanup(identity: DownloadContentIdentity) throws {
        try withLibraryTransaction {
            guard let row = try db.query("SELECT * FROM download_cleanup WHERE attempt_id=?",
                                        [.text(identity.attemptID.uuidString)]).first else { return }
            guard try Self.cleanupIdentity(from: row) == identity else {
                throw DownloadPersistenceError.sourceIdentityMismatch
            }
            // An old acknowledgement cannot reset a new attempt or delete a
            // completed job. It only removes the generation it was issued for.
            if let item = try downloadItem(jobID: identity.jobID), item.contentIdentity == identity {
                guard [.paused, .failed, .cancelled, .deleting].contains(item.state) else {
                    throw DownloadPersistenceError.invalidState
                }
                if item.state == .deleting {
                    try db.run("DELETE FROM download_job WHERE job_id=?", [.text(identity.jobID.uuidString)])
                } else {
                    try db.run("""
                        UPDATE download_job SET attempt_id=NULL,publication_state='none',page_count=NULL,
                            completed_pages=0,stored_bytes=0,manifest_sha256=NULL,updated_at=? WHERE job_id=?
                        """, [.int(Self.downloadNow()), .text(identity.jobID.uuidString)])
                }
            }
            try db.run("DELETE FROM download_page WHERE job_id=? AND attempt_id=?",
                       [.text(identity.jobID.uuidString), .text(identity.attemptID.uuidString)])
            try db.run("DELETE FROM download_cleanup WHERE attempt_id=?", [.text(identity.attemptID.uuidString)])
        }
    }

    /// Call before replacing even an identical facade. Durable attempt epochs
    /// prevent disable/re-enable and same-configuration replacement ABA.
    @discardableResult
    public func invalidateDownloadAttempts(sourceIDs: Set<Int64>) throws -> [DownloadContentIdentity] {
        try withLibraryTransaction { try invalidateDownloadSourceIDsInTransaction(sourceIDs) }
    }
}

extension LibraryStore {
    private func withDownloadTransaction<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try withLibraryTransaction {
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
    }

    private func requiredDownloadItem(_ id: UUID) throws -> DownloadItem {
        guard let item = try downloadItem(jobID: id) else { throw DownloadPersistenceError.jobNotFound }
        return item
    }

    private func validatedDownloadTarget(
        chapterID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> DownloadTarget {
        let target = try downloadTarget(chapterID: chapterID)
        guard target.manga.inLibrary else { throw DownloadPersistenceError.mangaNotInLibrary }
        guard target.isCurrentChapter else { throw DownloadPersistenceError.chapterNotCurrent }
        try verifySourceUpdateConfiguration(sourceID: target.manga.sourceId, expectedConfiguration: expectedConfiguration)
        return target
    }

    private func downloadLibraryRevision(_ mangaID: Int64) throws -> Int64 {
        guard let revision = try db.query("SELECT library_revision FROM manga WHERE id=?", [.int(mangaID)])
            .first?.int64("library_revision"), revision >= 0 else { throw DownloadPersistenceError.invalidStoredRecord }
        return revision
    }

    private func downloadOrigin(
        _ configuration: ExtensionExecutionConfiguration?
    ) throws -> (package: SQLiteBindable, fingerprint: SQLiteBindable, revision: SQLiteBindable) {
        guard let configuration else { return (.null, .null, .null) }
        return (.text(configuration.installed.packageName),
                .text(try ExtensionPreferenceBinding.fingerprint(configuration.installed)),
                configuration.snapshot.map { .int($0.revision) } ?? .null)
    }

    private func verifyQueuedDownloadOrigin(
        jobID: UUID, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws {
        guard let row = try db.query("""
            SELECT origin_package,origin_fingerprint,configuration_revision,library_revision,manga_id
            FROM download_job WHERE job_id=?
            """, [.text(jobID.uuidString)]).first,
              let mangaID = row.int64("manga_id"),
              row.int64("library_revision") == (try downloadLibraryRevision(mangaID)) else {
            throw DownloadPersistenceError.staleAttempt
        }
        if let expectedConfiguration {
            guard row.string("origin_package") == expectedConfiguration.installed.packageName,
                  row.string("origin_fingerprint") == (try ExtensionPreferenceBinding.fingerprint(expectedConfiguration.installed)),
                  row.int64("configuration_revision") == expectedConfiguration.snapshot?.revision else {
                throw DownloadPersistenceError.staleAttempt
            }
        } else {
            guard row.string("origin_package") == nil, row.string("origin_fingerprint") == nil,
                  row.int64("configuration_revision") == nil else { throw DownloadPersistenceError.staleAttempt }
        }
    }

    private func verifyDownloadIdentity(
        _ item: DownloadItem, target: DownloadTarget, allowLegacy: Bool = false
    ) throws {
        guard item.manga.id == target.manga.id, item.manga.sourceId == target.manga.sourceId,
              item.chapter.id == target.chapter.id else { throw DownloadPersistenceError.sourceIdentityMismatch }
        guard let row = try db.query("SELECT manga_url_digest,chapter_url_digest FROM download_job WHERE job_id=?",
                                     [.text(item.jobID.uuidString)]).first else { throw DownloadPersistenceError.jobNotFound }
        if allowLegacy, item.reason == .legacyUnverified,
           row.string("manga_url_digest") == "", row.string("chapter_url_digest") == "" { return }
        guard row.string("manga_url_digest") == Self.downloadDigest(target.manga.url),
              row.string("chapter_url_digest") == Self.downloadDigest(target.chapter.url) else {
            throw DownloadPersistenceError.sourceIdentityMismatch
        }
    }

    private func verifyDownloadAttempt(_ attempt: DownloadAttempt) throws -> DownloadItem {
        let item = try requiredDownloadItem(attempt.jobID)
        guard item.state == .downloading, item.revision == attempt.revision,
              item.contentIdentity == attempt.identity else { throw DownloadPersistenceError.staleAttempt }
        let target = try validatedDownloadTarget(chapterID: attempt.identity.chapterID,
                                                 expectedConfiguration: attempt.expectedConfiguration)
        try verifyDownloadIdentity(item, target: target)
        guard try downloadLibraryRevision(attempt.identity.mangaID) == attempt.libraryRevision else {
            throw DownloadPersistenceError.staleAttempt
        }
        try verifyQueuedDownloadOrigin(jobID: attempt.jobID, expectedConfiguration: attempt.expectedConfiguration)
        return item
    }

    private func downloadPublicationPhase(_ jobID: UUID) throws -> String {
        guard let phase = try db.query("SELECT publication_state FROM download_job WHERE job_id=?",
                                      [.text(jobID.uuidString)]).first?.string("publication_state") else {
            throw DownloadPersistenceError.jobNotFound
        }
        return phase
    }

    private func requireWorkingDownload(_ id: UUID) throws {
        guard try downloadPublicationPhase(id) == "working" else { throw DownloadPersistenceError.invalidState }
    }

    private func downloadPages(identity: DownloadContentIdentity) throws -> [DownloadPageReceipt] {
        try db.query("""
            SELECT ordinal,byte_count,sha256 FROM download_page WHERE job_id=? AND attempt_id=?
            ORDER BY ordinal LIMIT 2049
            """, [.text(identity.jobID.uuidString), .text(identity.attemptID.uuidString)]).map { row in
                guard let ordinal = row.int("ordinal"), let bytes = row.int64("byte_count"),
                      let hash = row.string("sha256") else { throw DownloadPersistenceError.invalidStoredRecord }
                let receipt = DownloadPageReceipt(ordinal: ordinal, byteCount: bytes, sha256: hash)
                try Self.validateDownloadReceipt(receipt, policy: downloadPolicy)
                return receipt
            }
    }

    private func verifyCompleteDownloadPages(item: DownloadItem, pages: [DownloadPageReceipt]) throws {
        guard let count = item.pageCount, count > 0, count <= downloadPolicy.maximumPageCount,
              pages.count == count, item.completedPages == count,
              pages.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else {
            throw DownloadPersistenceError.incompletePages
        }
        var bytes: Int64 = 0
        for page in pages {
            try Self.validateDownloadReceipt(page, policy: downloadPolicy)
            let (next, overflow) = bytes.addingReportingOverflow(page.byteCount)
            guard !overflow, next <= downloadPolicy.maximumChapterBytes else {
                throw DownloadPersistenceError.chapterLimitExceeded
            }
            bytes = next
        }
        guard bytes == item.storedBytes else { throw DownloadPersistenceError.manifestMismatch }
    }

    private func verifyDownloadManifest(
        item: DownloadItem, identity: DownloadContentIdentity, receipt: DownloadManifestReceipt
    ) throws {
        guard receipt.identity == identity, Self.validDownloadDigest(receipt.manifestSHA256),
              receipt.pages.count <= downloadPolicy.maximumPageCount else {
            throw DownloadPersistenceError.manifestMismatch
        }
        let pages = try downloadPages(identity: identity)
        try verifyCompleteDownloadPages(item: item, pages: pages)
        guard pages == receipt.pages, receipt.totalBytes == item.storedBytes else {
            throw DownloadPersistenceError.manifestMismatch
        }
    }

    private func downloadCleanup(jobID: UUID) throws -> [DownloadContentIdentity] {
        try db.query("SELECT * FROM download_cleanup WHERE job_id=? ORDER BY attempt_id",
                     [.text(jobID.uuidString)]).map(Self.cleanupIdentity(from:))
    }

    private func stopDownloadInTransaction(
        jobID: UUID, state: DownloadState, reason: DownloadFailureReason?, allowFinished: Bool = false
    ) throws -> DownloadMutation {
        let item = try requiredDownloadItem(jobID)
        if item.state == .deleting || (item.state == .finished && !allowFinished) {
            return DownloadMutation(item: item, cleanup: try downloadCleanup(jobID: jobID))
        }
        if item.state == state {
            return DownloadMutation(item: item, cleanup: try downloadCleanup(jobID: jobID))
        }
        if let identity = item.contentIdentity {
            try db.run("""
                INSERT INTO download_cleanup(
                    attempt_id,job_id,manga_id,chapter_id,source_id,manga_url_digest,chapter_url_digest,stored_bytes
                ) VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(attempt_id) DO NOTHING
                """, [.text(identity.attemptID.uuidString), .text(identity.jobID.uuidString),
                      .int(identity.mangaID), .int(identity.chapterID), .int(identity.sourceID),
                      .text(identity.mangaURLDigest), .text(identity.chapterURLDigest), .int(item.storedBytes)])
        }
        try db.run("UPDATE download_job SET state=?,revision=?,reason=?,updated_at=? WHERE job_id=?",
                   [.int(state.rawValue), .int(try nextDownloadRevision(item.revision)),
                    reason.map { .text($0.rawValue) } ?? .null, .int(Self.downloadNow()), .text(jobID.uuidString)])
        return DownloadMutation(item: try requiredDownloadItem(jobID), cleanup: try downloadCleanup(jobID: jobID))
    }

    private func invalidateDownloadSourceIDsInTransaction(_ ids: Set<Int64>) throws -> [DownloadContentIdentity] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try invalidateDownloadsInTransaction(
            where: "source_id IN (" + placeholders + ")", values: ids.sorted().map(SQLiteBindable.int),
            reason: .configurationChanged)
    }

    private func invalidateDownloadsInTransaction(
        where condition: String, values: [SQLiteBindable], reason: DownloadFailureReason
    ) throws -> [DownloadContentIdentity] {
        var cleanup: [DownloadContentIdentity] = []
        for row in try db.query("SELECT job_id FROM download_job WHERE state IN (0,1) AND (" + condition + ")", values) {
            guard let text = row.string("job_id"), let id = UUID(uuidString: text) else {
                throw DownloadPersistenceError.invalidStoredRecord
            }
            cleanup += try stopDownloadInTransaction(jobID: id, state: .paused, reason: reason).cleanup
        }
        return cleanup
    }

    private func nextDownloadQueueOrder() throws -> Int64 {
        let current = try db.query("SELECT MAX(queue_order) AS value FROM download_job").first?.int64("value") ?? -1
        guard current < Int64.max else { throw DownloadPersistenceError.invalidStoredRecord }
        return current + 1
    }

    private func nextDownloadRevision(_ current: Int64) throws -> Int64 {
        guard current > 0, current < Int64.max else { throw DownloadPersistenceError.invalidStoredRecord }
        return current + 1
    }

    private func downloadQueueSummary() throws -> DownloadQueueSummary {
        var counts: [DownloadState: Int] = [:]
        for row in try db.query("SELECT state,COUNT(*) AS count FROM download_job GROUP BY state") {
            guard let raw = row.int("state"), let state = DownloadState(rawValue: raw),
                  let count = row.int("count") else { throw DownloadPersistenceError.invalidStoredRecord }
            counts[state] = count
        }
        let jobBytes = try db.query("SELECT COALESCE(SUM(stored_bytes),0) AS value FROM download_job").first?.int64("value") ?? 0
        let cleanupBytes = try db.query("SELECT COALESCE(SUM(stored_bytes),0) AS value FROM download_cleanup")
            .first?.int64("value") ?? 0
        let orphanBytes = try db.query("""
            SELECT COALESCE(SUM(c.stored_bytes),0) AS value FROM download_cleanup c
            WHERE NOT EXISTS(SELECT 1 FROM download_job j WHERE j.attempt_id=c.attempt_id)
            """).first?.int64("value") ?? 0
        let (storedBytes, overflow) = jobBytes.addingReportingOverflow(orphanBytes)
        guard !overflow else { throw DownloadPersistenceError.invalidStoredRecord }
        return DownloadQueueSummary(queued: counts[.queued] ?? 0, active: counts[.downloading] ?? 0,
                                    finished: counts[.finished] ?? 0, paused: counts[.paused] ?? 0,
                                    failed: counts[.failed] ?? 0, cancelled: counts[.cancelled] ?? 0,
                                    deleting: counts[.deleting] ?? 0, storedBytes: storedBytes,
                                    cleanupBytes: cleanupBytes, quotaBytes: downloadPolicy.quotaBytes)
    }

    private func downloadChapterStateRows(
        where condition: String, values: [SQLiteBindable]
    ) throws -> [Int64: DownloadChapterState] {
        var result: [Int64: DownloadChapterState] = [:]
        for row in try db.query("SELECT chapter_id,job_id,state,reason FROM download_job WHERE " + condition, values) {
            guard let chapterID = row.int64("chapter_id"), let text = row.string("job_id"),
                  let jobID = UUID(uuidString: text), let raw = row.int("state"), let state = DownloadState(rawValue: raw) else {
                throw DownloadPersistenceError.invalidStoredRecord
            }
            let reason = row.string("reason").flatMap(DownloadFailureReason.init(rawValue:))
            guard row.string("reason") == nil || reason != nil else { throw DownloadPersistenceError.invalidStoredRecord }
            result[chapterID] = DownloadChapterState(jobID: jobID, state: state, reason: reason)
        }
        return result
    }

    private static func downloadNow() -> Int64 { Int64(Date().timeIntervalSince1970) }

    private static func downloadDigest(_ value: String) -> String {
        APKSignatureVerifier.apkSHA256(Array(value.utf8))
    }

    private static func validDownloadDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validateDownloadReceipt(_ receipt: DownloadPageReceipt, policy: DownloadPolicy) throws {
        guard receipt.ordinal >= 0, receipt.ordinal < policy.maximumPageCount, receipt.byteCount > 0,
              receipt.byteCount <= Int64(policy.maximumPageBytes), validDownloadDigest(receipt.sha256) else {
            throw DownloadPersistenceError.invalidReceipt
        }
    }

    private static func downloadTarget(from row: SQLiteDatabase.Row) throws -> DownloadTarget {
        guard let manga = manga(from: row), let mangaID = manga.id,
              let chapterID = row.int64("chapter_id"), let url = row.string("chapter_url"),
              let name = row.string("chapter_name") else { throw DownloadPersistenceError.invalidStoredRecord }
        return DownloadTarget(manga: manga, chapter: joinedChapter(from: row, id: chapterID, mangaID: mangaID,
                                                                  url: url, name: name),
                              isCurrentChapter: row.bool("chapter_is_current"))
    }

    private static func downloadItem(from row: SQLiteDatabase.Row) throws -> DownloadItem {
        let target = try downloadTarget(from: row)
        guard let text = row.string("job_id"), let jobID = UUID(uuidString: text),
              let raw = row.int("state"), let state = DownloadState(rawValue: raw),
              let revision = row.int64("revision"), revision > 0,
              let mangaID = row.int64("captured_manga_id"), mangaID == target.manga.id,
              let sourceID = row.int64("captured_source_id"), sourceID == target.manga.sourceId,
              let mangaDigest = row.string("manga_url_digest"), let chapterDigest = row.string("chapter_url_digest"),
              let completedPages = row.int("completed_pages"), completedPages >= 0,
              let storedBytes = row.int64("stored_bytes"), storedBytes >= 0,
              let queueOrder = row.int64("queue_order"), let createdAt = row.int64("created_at"),
              let updatedAt = row.int64("updated_at") else { throw DownloadPersistenceError.invalidStoredRecord }
        let reason = row.string("reason").flatMap(DownloadFailureReason.init(rawValue:))
        guard row.string("reason") == nil || reason != nil else { throw DownloadPersistenceError.invalidStoredRecord }
        let legacy = reason == .legacyUnverified && mangaDigest.isEmpty && chapterDigest.isEmpty
        guard legacy || (mangaDigest == downloadDigest(target.manga.url) && chapterDigest == downloadDigest(target.chapter.url)) else {
            throw DownloadPersistenceError.sourceIdentityMismatch
        }
        var identity: DownloadContentIdentity?
        if let text = row.string("attempt_id") {
            guard let attemptID = UUID(uuidString: text), !legacy else { throw DownloadPersistenceError.invalidStoredRecord }
            identity = DownloadContentIdentity(jobID: jobID, attemptID: attemptID, mangaID: mangaID,
                                               chapterID: target.chapter.id!, sourceID: sourceID,
                                               mangaURLDigest: mangaDigest, chapterURLDigest: chapterDigest)
        }
        return DownloadItem(jobID: jobID, revision: revision, state: state, manga: target.manga,
                            chapter: target.chapter, isCurrentChapter: target.isCurrentChapter, contentIdentity: identity,
                            pageCount: row.int("page_count"), completedPages: completedPages, storedBytes: storedBytes,
                            reason: reason, manifestSHA256: row.string("manifest_sha256"), queueOrder: queueOrder,
                            createdAt: createdAt, updatedAt: updatedAt)
    }

    private static func cleanupIdentity(from row: SQLiteDatabase.Row) throws -> DownloadContentIdentity {
        guard let jobText = row.string("job_id"), let jobID = UUID(uuidString: jobText),
              let attemptText = row.string("attempt_id"), let attemptID = UUID(uuidString: attemptText),
              let mangaID = row.int64("manga_id"), let chapterID = row.int64("chapter_id"),
              let sourceID = row.int64("source_id"), let mangaDigest = row.string("manga_url_digest"),
              let chapterDigest = row.string("chapter_url_digest"),
              validDownloadDigest(mangaDigest), validDownloadDigest(chapterDigest) else {
            throw DownloadPersistenceError.invalidStoredRecord
        }
        return DownloadContentIdentity(jobID: jobID, attemptID: attemptID, mangaID: mangaID,
                                       chapterID: chapterID, sourceID: sourceID,
                                       mangaURLDigest: mangaDigest, chapterURLDigest: chapterDigest)
    }
}

#endif
