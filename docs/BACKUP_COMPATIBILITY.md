# Backup decoding and restoration scope

## Verified upstream format — 2026-10-04

Mihon writes gzip-wrapped protobuf and reads gzip or raw protobuf. This was
checked at main `7aacaa349019ff42b8b05403d8beebe94c8f6dfc`, release v0.20.4
(`df6507256acce8e7f3660783a3db6dbd1a31b6b5`) and the inspected Tachiyomi-era
history (`a9c7cbf2c43959ae7ad9df3baa2306a254dd57e3`, 2024-01-13):

- [Mihon creator](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/create/BackupCreator.kt)
  and [decoder](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/BackupDecoder.kt).
- [Release creator](https://github.com/mihonapp/mihon/blob/df6507256acce8e7f3660783a3db6dbd1a31b6b5/app/src/main/java/eu/kanade/tachiyomi/data/backup/create/BackupCreator.kt).
- [Tachiyomi-era creator](https://github.com/mihonapp/mihon/blob/a9c7cbf2c43959ae7ad9df3baa2306a254dd57e3/app/src/main/java/eu/kanade/tachiyomi/data/backup/create/BackupCreator.kt).

The earlier document's “current zstd / legacy zlib” and “schema work done”
claims were incorrect. Generic zlib support in the kit did not prove backup
interoperability. No zlib or zstd decompression is supported for backups; no
zstd dependency is needed to read the verified producers above. Older JSON
backups, arbitrary forks and every historical Tachiyomi schema are outside
the demonstrated contract.

## Decoder contract

`TachibkReader.decode` returns typed manga, chapters, history, categories and
source labels together with a coverage report. It performs no file access,
source requests, database writes, source mapping or extension activation.
Consumers must inspect coverage before describing an import as complete.

The gzip path accepts one complete member. It checks optional-header bounds
and FHCRC, the complete DEFLATE body, CRC-32 and ISIZE, and enforces the output
limit while expanding. Additional bytes and concatenated members are rejected;
concatenation is valid general gzip but intentionally outside this backup
policy. Existing repository-index callers retain their separate gzip entry
point. Raw protobuf is checked against the same payload/schema limits and
does not need manga to be the first field. Non-gzip header hints cannot override
a successful raw decode: valid unknown protobuf fields can resemble other
compression headers.

The backup-specific cursor checks wire types, varint/length bounds, required
identity fields, UTF-8 and cumulative budgets. Malformed supported nested
messages fail the decode instead of disappearing through `try?`/`compactMap`.
Singular values follow protobuf's last-occurrence rule. Category references
accept expanded or packed varints; current Mihon's unannotated Kotlin list
uses expanded encoding. Packed support is additional interoperability coverage.
Source IDs, category orders and chapter progress/order retain signed Int64
precision. Dates retain their upstream units in this layer.
Booleans must be 0 or 1, chapter numbers must be finite, and the update strategy
must be a known enum case; these are explicit acceptance restrictions.

Limits are immutable, cumulative over the complete decode and can only be
lowered by a caller. Overwritten singular values still consume their budgets.

| Resource | Default and hard maximum |
| --- | ---: |
| Input / expanded payload | 32 MiB / 64 MiB |
| Interpreted fields | 500,000 |
| Manga / categories / source records | 10,000 / 1,000 / 10,000 |
| Chapters / history entries / category references | 100,000 each |
| Total decoded string bytes | 32 MiB |
| Individual string / description / URL | 256 KiB / 256 KiB / 4 KiB |
| Interpreted message depth | 8 |

Unsupported messages are skipped opaquely after checking their outer wire type
and length. Their internal fields are not validated or traversed, and their
bytes remain subject to the input/payload bounds. Cancellation is checked during
expansion, checksums and schema traversal.

| Record | Supported meaning |
| --- | --- |
| Root | Manga 1, categories 2, descriptive sources 101 |
| Manga | Required source 1 and URL 2; metadata, thumbnail, date added, chapters, category references, favorite, history, update strategy and initialization |
| Favorite | Field 100 defaults to **true**; an explicit false remains false |
| Category | Name, order, ID and flags; manga references point to **order**, not category ID |
| Chapter | Required URL/name; scanlator, read/bookmark, last page, fetch/upload dates, Float chapter number and source order |
| History | Required exact chapter URL and last-read timestamp; duration defaults to zero |
| Source | Full numeric ID and label; neither establishes trust or publisher identity |

The favorite default follows [BackupManga](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupManga.kt).
Category order references follow
[MangaBackupCreator](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/create/creators/MangaBackupCreator.kt)
and [MangaRestorer](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/restore/restorers/MangaRestorer.kt).
Other field declarations are in the same pinned
[model directory](https://github.com/mihonapp/mihon/tree/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/models).

Preferences, trackers, extension stores, legacy records, notes/memos and other
unrepresented fields have explicit coverage counts. A preference value is a
sealed message, not a UTF-8 string; a store's field 1 is its index URL, not its
name. The report carries no executable settings, trusted signing keys or raw
secrets. Unsupported data is reported, not preserved as a lossless re-export
format. Keep the original input when a later import needs that data.

`read` remains a compatibility projection and includes a coverage entry.
Its category order and chapter progress/order values now use Int64; clients
of the earlier API must adapt rather than narrow these values silently.
New consumers should use `decode` to retain category IDs/flags and coverage.

## Verification and remaining work

Synthetic wire regressions cover malformed input and exact boundaries; gzip
fixtures from an independent zlib compressor exercise stored, fixed and dynamic
blocks. Kotlin reference-serializer fixtures and their provenance are maintained
under `Tests/backups/`. These test deterministic format behavior; they do not
represent a user backup exported from a running Android application.

The implementation PR records the final suite/build evidence for its exact
commit. A passing decoder suite does not establish restoration or Files UI.
The next product work is a versioned Kami library export, immutable restore
preview, atomic merge and a report of unavailable/conflicting sources and
unsupported fields. Native snapshots must include all history, hidden chapters,
duration and durable discovery state.

Restoration must match exact source/URL identities and preserve reading state.
Fuzzy title or chapter-number matching belongs to a separately chosen source
migration flow. FoolSlide's configurable deployment needs an explicit content
binding. MangaDex extension URL shapes differ from Kami's bare UUIDs; a native
mapping requires verified source-ID and URL-shape evidence. Backup metadata
must never install/enable extensions or grant signing trust. Full settings,
tracking, `.tachibk` export and broad fork compatibility remain separate work.
