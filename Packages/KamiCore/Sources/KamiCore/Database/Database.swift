import Foundation

#if canImport(SQLite3)

/// Versioned schema migrations. Every change ships as a new step; the
/// `user_version` pragma tracks the applied version.
enum Migrations {
    static let latest: Int = 2

    static let steps: [Int: String] = [
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
        2: """
        ALTER TABLE installed_extension ADD COLUMN apk_sha256 TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN signature_scheme TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN current_signers TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE installed_extension ADD COLUMN signer_history TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE installed_extension ADD COLUMN trust_source TEXT NOT NULL DEFAULT '';
        ALTER TABLE installed_extension ADD COLUMN source_ids TEXT NOT NULL DEFAULT '[]';
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
