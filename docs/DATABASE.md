# Database

SQLite via a thin system-library wrapper (`KamiCore/Database/SQLiteDatabase.swift`,
no third-party dependency). Single database at
`~/Library/Application Support/Kami/kami.sqlite` (WAL mode, foreign keys on).

## Schema (v2 — `Database.swift` migrations)

| Table | Purpose |
|---|---|
| `manga` | metadata + library membership; unique per `(source_id, url)` |
| `category` / `manga_category` | categories, many-to-many |
| `chapter` | per-manga chapters; read/bookmark/progress state |
| `history` | reading history (manga, chapter, last_read, duration) |
| `source_preference` | per-source key/value store (extension prefs bridge) |
| `extension_repo` | persisted extension stores; URL, name, normalized/pinned signing key, and add time |
| `installed_extension` | installed APK path/hash, package/version, repository, install time, enabled state, verified signature scheme/current signers/history, sticky trust source, and declared source IDs |
| `download` | download queue state |

Migrations are versioned (`PRAGMA user_version`); every schema change ships
as a new numbered step in a transaction. Tests cover migration idempotence
and the critical invariant: **chapter refresh preserves read/bookmark/progress
state by URL matching** (`LibraryStore.replaceChapters`).

All access is serialized through the `LibraryStore` actor; no view touches
SQL directly.

Repository refresh may update display metadata, but a non-empty signing key is
pinned on first observation: removing or changing that key fails closed. An
installed extension update preserves its existing enabled state and original
trust root. Startup restoration reads only enabled records and issues a fresh
admission capability after the exact persisted APK file is rehashed,
cryptographically re-verified, and matched against all persisted identity
fields; a failed restore is disabled by the app.
