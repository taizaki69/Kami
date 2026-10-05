# Database

Reviewed **2026-10-04** against `main` at `a479806`. This is the schema-v2
main snapshot; the [continuation stack](PROJECT_STATUS.md) reaches schema v7.

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
| `source_preference` | per-source key/value scaffold; production preference UI is not wired on main |
| `extension_repo` | persisted extension stores; URL, name, normalized/pinned signing key, and add time |
| `installed_extension` | installed APK path/hash, package/version, repository, install time, enabled state, verified signature scheme/current signers/history, sticky trust source, and declared source IDs |
| `download` | queue-state scaffold; main has no completed download manager |

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

## Open continuation changes

PRs #10–20 add category management, typed FoolSlide settings, discovery state,
download storage, backup snapshots, atomic reading state, deployment binding
and mutation epochs/contexts. PRs #22–23 add reviewed native restore and the
measured English MangaDex Mihon adapter using atomic database merges. Read the
pinned [continuation database guide](https://github.com/taizaki69/Kami/blob/2251ffc6034471434dca867e1eced6cbf889d38e/docs/DATABASE.md)
when changing those branches. Do not apply a schema-v2 description to schema-v7
work or treat `LibraryStore` actor serialization as a complete stale-work gate.
