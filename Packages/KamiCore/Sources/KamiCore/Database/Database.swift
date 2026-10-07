import Foundation

#if canImport(SQLite3)

/// Versioned schema migrations. Every change ships as a new step; the
/// `user_version` pragma tracks the applied version.
enum Migrations {
    static let latest: Int = 9

    static let steps: [Int: String] = [
        9: """
        CREATE TABLE library_notification_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
            revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
            scan_cursor INTEGER NOT NULL CHECK(typeof(scan_cursor)='integer' AND scan_cursor>=0),
            batch_id TEXT,
            chapter_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(chapter_count)='integer' AND chapter_count>=0),
            incomplete INTEGER NOT NULL DEFAULT 0 CHECK(incomplete IN (0,1)),
            outcome TEXT CHECK(outcome IN ('attempting','submitted','unconfirmed')),
            CHECK((batch_id IS NULL AND outcome IS NULL AND chapter_count=0) OR
                  (length(CAST(batch_id AS BLOB))=36 AND outcome IS NOT NULL AND chapter_count>0))
        );
        INSERT INTO library_notification_state(singleton,enabled,revision,scan_cursor) VALUES (1,0,1,0);
        """,
        8: """
        ALTER TABLE manga ADD COLUMN last_library_update_attempt INTEGER NOT NULL DEFAULT 0
            CHECK(typeof(last_library_update_attempt)='integer' AND last_library_update_attempt>=0);
        """,
        7: """
        CREATE TABLE source_content_binding (
            source_id INTEGER PRIMARY KEY CHECK(source_id=6351052922295965587),
            kind TEXT NOT NULL CHECK(typeof(kind)='text' AND kind IN ('deployment','unresolved')),
            deployment_url TEXT,
            revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
            CHECK((kind='unresolved' AND deployment_url IS NULL) OR
                  (kind='deployment' AND typeof(deployment_url)='text'
                   AND length(CAST(deployment_url AS BLOB)) BETWEEN 1 AND 4096
                   AND instr(CAST(deployment_url AS BLOB),X'00')=0))
        );
        """,
        6: """
        CREATE TABLE library_data_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            epoch BLOB NOT NULL CHECK(typeof(epoch)='blob' AND length(epoch)=16)
        );
        INSERT INTO library_data_state(singleton,epoch) VALUES (1,randomblob(16));
        """,
        1: """
        CREATE TABLE IF NOT EXISTS manga (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_id INTEGER NOT NULL,
            url TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            alt_titles TEXT NOT NULL DEFAULT '[]',
            thumbnail_url TEXT,
            author TEXT,
            artist TEXT,
            description TEXT,
            genres TEXT NOT NULL DEFAULT '[]',
            status INTEGER NOT NULL DEFAULT 0,
            in_library INTEGER NOT NULL DEFAULT 0,
            date_added INTEGER NOT NULL DEFAULT 0,
            date_updated INTEGER NOT NULL DEFAULT 0,
            last_fetched INTEGER NOT NULL DEFAULT 0,
            update_strategy TEXT NOT NULL DEFAULT 'ALWAYS_UPDATE',
            initialized INTEGER NOT NULL DEFAULT 0,
            UNIQUE(source_id, url)
        );
        CREATE INDEX IF NOT EXISTS idx_manga_library ON manga(in_library);

        CREATE TABLE IF NOT EXISTS category (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            sort_order INTEGER NOT NULL DEFAULT 0,
            flags INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS manga_category (
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            category_id INTEGER NOT NULL REFERENCES category(id) ON DELETE CASCADE,
            PRIMARY KEY (manga_id, category_id)
        );

        CREATE TABLE IF NOT EXISTS chapter (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            source_order INTEGER NOT NULL DEFAULT 0,
            url TEXT NOT NULL,
            name TEXT NOT NULL,
            scanlator TEXT,
            number REAL NOT NULL DEFAULT -1,
            date_upload INTEGER NOT NULL DEFAULT 0,
            date_fetch INTEGER NOT NULL DEFAULT 0,
            read INTEGER NOT NULL DEFAULT 0,
            bookmark INTEGER NOT NULL DEFAULT 0,
            last_page_read INTEGER NOT NULL DEFAULT 0,
            UNIQUE(manga_id, url)
        );
        CREATE INDEX IF NOT EXISTS idx_chapter_manga ON chapter(manga_id);

        CREATE TABLE IF NOT EXISTS history (
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            chapter_id INTEGER NOT NULL REFERENCES chapter(id) ON DELETE CASCADE,
            last_read INTEGER NOT NULL DEFAULT 0,
            read_duration INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (manga_id, chapter_id)
        );

        CREATE TABLE IF NOT EXISTS source_preference (
            source_id INTEGER NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (source_id, key)
        );

        CREATE TABLE IF NOT EXISTS extension_repo (
            url TEXT PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            added_at INTEGER NOT NULL DEFAULT 0,
            trusted INTEGER NOT NULL DEFAULT 0,
            signing_key TEXT
        );

        CREATE TABLE IF NOT EXISTS installed_extension (
            package_name TEXT PRIMARY KEY,
            version_name TEXT NOT NULL,
            version_code INTEGER NOT NULL,
            apk_path TEXT NOT NULL,
            repo_url TEXT,
            installed_at INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS download (
            chapter_id INTEGER PRIMARY KEY REFERENCES chapter(id) ON DELETE CASCADE,
            state INTEGER NOT NULL DEFAULT 0,
            progress REAL NOT NULL DEFAULT 0,
            tries INTEGER NOT NULL DEFAULT 0,
            queue_order INTEGER NOT NULL DEFAULT 0
        );
        """,
        5: """
        CREATE TABLE download_job (
            job_id TEXT PRIMARY KEY,
            chapter_id INTEGER NOT NULL UNIQUE REFERENCES chapter(id) ON DELETE CASCADE,
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            source_id INTEGER NOT NULL,
            manga_url_digest TEXT NOT NULL,
            chapter_url_digest TEXT NOT NULL,
            state INTEGER NOT NULL CHECK(state IN (0,1,2,3,4,5,6)),
            revision INTEGER NOT NULL CHECK(revision > 0),
            attempt_id TEXT,
            library_revision INTEGER NOT NULL DEFAULT 0,
            origin_package TEXT,
            origin_fingerprint TEXT,
            configuration_revision INTEGER,
            publication_state TEXT NOT NULL DEFAULT 'none'
                CHECK(publication_state IN ('none','working','prepared','complete')),
            page_count INTEGER CHECK(page_count BETWEEN 1 AND 2048),
            completed_pages INTEGER NOT NULL DEFAULT 0 CHECK(completed_pages >= 0),
            stored_bytes INTEGER NOT NULL DEFAULT 0 CHECK(stored_bytes >= 0),
            manifest_sha256 TEXT,
            reason TEXT,
            queue_order INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX download_queue ON download_job(state,queue_order,job_id);
        CREATE UNIQUE INDEX one_active_download ON download_job(state) WHERE state=1;
        CREATE TABLE download_page (
            job_id TEXT NOT NULL REFERENCES download_job(job_id) ON DELETE CASCADE,
            attempt_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 2047),
            byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 33554432),
            sha256 TEXT NOT NULL CHECK(length(sha256)=64),
            PRIMARY KEY(job_id,attempt_id,ordinal)
        );
        -- No job foreign key: cleanup survives deletion of a domain row.
        CREATE TABLE download_cleanup (
            attempt_id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL,
            manga_id INTEGER NOT NULL,
            chapter_id INTEGER NOT NULL,
            source_id INTEGER NOT NULL,
            manga_url_digest TEXT NOT NULL,
            chapter_url_digest TEXT NOT NULL,
            stored_bytes INTEGER NOT NULL CHECK(stored_bytes >= 0)
        );
        -- Legacy progress and "finished" were never evidence of files.
        INSERT INTO download_job(
            job_id,chapter_id,manga_id,source_id,manga_url_digest,chapter_url_digest,
            state,revision,library_revision,reason,queue_order,created_at,updated_at
        )
        SELECT upper(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-' ||
            hex(randomblob(2)) || '-' || hex(randomblob(2)) || '-' || hex(randomblob(6))),
            c.id,m.id,m.source_id,'','',4,1,m.library_revision,'legacyUnverified',
            d.queue_order,0,0
        FROM download d JOIN chapter c ON c.id=d.chapter_id JOIN manga m ON m.id=c.manga_id;
        DROP TABLE download;
        """,
        2: """
        ALTER TABLE installed_extension ADD COLUMN apk_sha256 TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN signature_scheme TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN current_signers TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE installed_extension ADD COLUMN signer_history TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE installed_extension ADD COLUMN trust_source TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN source_ids TEXT NOT NULL DEFAULT '[]';
        """,
        3: """
        CREATE TABLE installed_extension_preferences (
            package_name TEXT PRIMARY KEY REFERENCES installed_extension(package_name) ON DELETE CASCADE,
            identity_fingerprint TEXT NOT NULL CHECK(length(identity_fingerprint) = 64),
            schema_revision INTEGER NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            user_values TEXT NOT NULL CHECK(length(CAST(user_values AS BLOB)) <= 16384)
        );
        """,
        4: """
        ALTER TABLE manga ADD COLUMN library_revision INTEGER NOT NULL DEFAULT 0;
        CREATE TRIGGER manga_library_revision AFTER UPDATE OF in_library ON manga
        WHEN OLD.in_library != NEW.in_library
        BEGIN
            UPDATE manga SET library_revision=library_revision+1 WHERE id=NEW.id;
        END;

        ALTER TABLE chapter ADD COLUMN is_current INTEGER NOT NULL DEFAULT 1 CHECK(is_current IN (0,1));
        CREATE INDEX idx_chapter_current ON chapter(manga_id,is_current,source_order);
        CREATE TABLE chapter_discovery_baseline (
            manga_id INTEGER PRIMARY KEY REFERENCES manga(id) ON DELETE CASCADE,
            established_at INTEGER NOT NULL
        );
        CREATE TABLE known_chapter (
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            first_seen INTEGER NOT NULL,
            detected_at INTEGER,
            PRIMARY KEY(manga_id, url)
        );
        INSERT INTO chapter_discovery_baseline(manga_id, established_at)
            SELECT DISTINCT manga_id, 0 FROM chapter;
        INSERT INTO known_chapter(manga_id, url, first_seen, detected_at)
            SELECT manga_id, url, 0, NULL FROM chapter;
        CREATE INDEX idx_chapter_discovery_feed
            ON known_chapter(detected_at DESC,manga_id DESC,url DESC) WHERE detected_at IS NOT NULL;

        CREATE TABLE library_update_scan (
            scan_id TEXT PRIMARY KEY,
            status TEXT NOT NULL CHECK(status IN ('running','completed','cancelled','interrupted')),
            started_at INTEGER NOT NULL,
            finished_at INTEGER,
            total INTEGER NOT NULL CHECK(total >= 0)
        );
        CREATE UNIQUE INDEX one_running_library_update
            ON library_update_scan(status) WHERE status='running';
        CREATE TABLE library_update_target (
            scan_id TEXT NOT NULL REFERENCES library_update_scan(scan_id) ON DELETE CASCADE,
            manga_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            library_revision INTEGER NOT NULL,
            outcome TEXT NOT NULL DEFAULT 'pending'
                CHECK(outcome IN ('pending','checked','skipped','failed','cancelled')),
            new_chapters INTEGER NOT NULL DEFAULT 0 CHECK(new_chapters >= 0),
            established_baseline INTEGER NOT NULL DEFAULT 0 CHECK(established_baseline IN (0,1)),
            reason TEXT CHECK(reason IN (
                'sourceUnavailable','configurationChanged','onlyFetchOnce',
                'requestFailed','removedFromLibrary','cancelled'
            )),
            PRIMARY KEY(scan_id, manga_id)
        );
        """,
    ]

    static func apply(_ db: SQLiteDatabase) throws {
        let current = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard current < latest else { return }
        for version in (current + 1)...latest {
            guard let sql = steps[version] else { continue }
            try db.execute("BEGIN")
            do {
                try db.execute(sql)
                if version == 7 { try SourceContentBindingPersistence.migrate(db) }
                try db.execute("PRAGMA user_version=\(version)")
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }
}

#endif
