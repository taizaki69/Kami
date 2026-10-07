# Database

SQLite via a thin system-library wrapper (`KamiCore/Database/SQLiteDatabase.swift`,
no third-party dependency). Single database at
`~/Library/Application Support/Kami/kami.sqlite` (WAL mode, foreign keys on).

## Schema (v9 — `Database.swift` migrations)

| Table | Purpose |
|---|---|
| `manga` | metadata + library membership; unique per `(source_id, url)`; last attempted scan sequence for fair update rotation (schema 8) |
| `category` / `manga_category` | categories, many-to-many |
| `chapter` | per-manga chapters; read/bookmark/progress state; missing source rows retained as non-current |
| `history` | reading history (manga, chapter, last_read, duration) |
| `source_preference` | per-source key/value store (extension prefs bridge) |
| `extension_repo` | persisted extension stores; URL, name, normalized/pinned signing key, and add time |
| `installed_extension` | installed APK path/hash, package/version, repository, install time, enabled state, verified signature scheme/current signers/history, sticky trust source, and declared source IDs |
| `installed_extension_preferences` | authenticated settings bound to installation identity and revision |
| `chapter_discovery_baseline` / `known_chapter` | silent initial baseline and durable chapter discovery feed |
| `library_update_scan` / `library_update_target` | shared manual/automatic scan lifetime and finite per-manga outcomes |
| `library_notification_state` | default-off alert preference, editor revision, scan watermark and last batch/outcome (schema 9) |
| `download_job` / `download_page` | durable queue, fresh attempt revisions, ordered page receipts and prepared/complete publication |
| `download_cleanup` | generation-specific cleanup retained until file removal is acknowledged |
| `library_data_state` | durable epoch for database-issued reading and mutation targets (schema 6) |
| `source_content_binding` | durable configurable-source content namespace, independent of executable settings (schema 7) |

Migrations are versioned (`PRAGMA user_version`); every schema change ships
as a new numbered step in a transaction. Tests cover migration idempotence
and the critical invariant: **chapter refresh preserves read/bookmark/progress
state by URL matching** (`LibraryStore.replaceChapters`).

All access is serialized through the `LibraryStore` actor; no view touches
SQL directly.

Schema 9 adds a singleton notification journal. Enabling captures the latest
started scan; only later terminal scans contribute to a claimed digest. The
watermark and attempt persist atomically before the OS call. An uncertain
submission is reconciled, never automatically replayed. This operational state
is local and excluded from backup v1. Scan-history pruning must also preserve
or rebase the notification watermark. See [chapter notifications](CHAPTER_NOTIFICATIONS.md).

Schema 8 adds `manga.last_library_update_attempt`, initially zero. A current
pending target is claimed immediately before dispatch; the scan sequence survives
failure, cancellation and process interruption without establishing a successful
chapter baseline. Later snapshots prioritize the oldest attempted manga and
source queues. Scan-history pruning must preserve or rebase this sequence.
The default-off automatic schedule is a separate bounded JSON file, not part of
the library backup. See [automatic updates](AUTOMATIC_UPDATES.md).

Download schema 5 migrates old scaffold rows to paused/unverified regardless of
their former state. An old progress value cannot prove local files exist.
Attempt mutations check current library membership, source identity/settings,
revision and ordered receipts. Local completion lookup requires the sealed
database generation and does not require an enabled source. Filesystem integrity
and read leases are a separate boundary described in [Downloads](DOWNLOADS.md).

Repository refresh may update display metadata, but a non-empty signing key is
pinned on first observation: removing or changing that key fails closed. An
installed extension update preserves its existing enabled state and original
trust root. Startup restoration reads only enabled records and issues a fresh
admission capability after the exact persisted APK file is rehashed,
cryptographically re-verified, and matched against all persisted identity
fields; a failed restore is disabled by the app.

## Native backup restoration

A restore preview binds immutable validated bytes to its issuing store, durable
epoch, exact domain/identity/configuration fingerprint and SQLite change stamp.
Commit starts `BEGIN IMMEDIATE`, rejects active durable scans/download workers
and revalidates those dependencies before writing. One transaction merges
categories, manga, chapter state, history and discovery knowledge, then rotates
the epoch. Errors and pre-commit cancellation roll everything back. Successful
COMMIT remains success if cancellation arrives while the UI awaits the result.

Existing metadata/current chapter lists, downloads/files, runtime settings,
repositories and signing trust survive unchanged. Archive source descriptions
are not installation or request authority. See [merge and source-conflict
rules](NATIVE_BACKUPS.md). Restore was introduced on schema 7 and continues on
the current schema. Existing attempt sequences stay local; new restored manga
receive the schema default. This operational field does not change backup v1.
