# Database

SQLite via a thin system-library wrapper (`KamiCore/Database/SQLiteDatabase.swift`,
no third-party dependency). Single database at
`~/Library/Application Support/Kami/kami.sqlite` (WAL mode, foreign keys on).

## Schema (v1 — `Database.swift` migrations)

| Table | Purpose |
|---|---|
| `manga` | metadata + library membership; unique per `(source_id, url)` |
| `category` / `manga_category` | categories, many-to-many |
| `chapter` | per-manga chapters; read/bookmark/progress state |
| `history` | reading history (manga, chapter, last_read, duration) |
| `source_preference` | per-source key/value store (extension prefs bridge) |
| `extension_repo` | added extension stores (url, name, trust, signing key) |
| `installed_extension` | installed APK metadata |
| `download` | download queue state |

Migrations are versioned (`PRAGMA user_version`); every schema change ships
as a new numbered step in a transaction. Tests cover migration idempotence
and the critical invariant: **chapter refresh preserves read/bookmark/progress
state by URL matching** (`LibraryStore.replaceChapters`).

All access is serialized through the `LibraryStore` actor; no view touches
SQL directly.
