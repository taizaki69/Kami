# Backup compatibility and restoration scope

Reviewed **2026-10-04** against `main` at `a479806`. Main still contains the
early `TachibkReader`; the corrected decoder and native export are in open
PRs. See [project status](PROJECT_STATUS.md) for their exact heads.

## Corrected format evidence

The earlier claims that current Mihon uses zstd, historical Tachiyomi uses
zlib, and only decompression remained were incorrect. The checked Mihon
producer at `7aacaa349019ff42b8b05403d8beebe94c8f6dfc` writes **gzip-wrapped
protobuf**; its decoder accepts gzip or raw protobuf. See the pinned
[creator](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/create/BackupCreator.kt)
and [decoder](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/BackupDecoder.kt).
This is evidence for pinned producers, not every historical backup or fork.

Main's zlib-oriented parser and old field mapping are not an interoperable
implementation of that contract. Generic compression support alone does not
validate the backup schema. The prior field-number table has therefore been
removed; it must not be used to implement import.

## Implemented in open PRs

| Work | Scope and boundary |
| --- | --- |
| [PR #14](https://github.com/taizaki69/Kami/pull/14) | Bounded gzip/raw protobuf decoding; typed records, cumulative limits, cancellation, malformed-input rejection and an explicit unsupported-field coverage report |
| [PR #15](https://github.com/taizaki69/Kami/pull/15) | Native Kami versioned JSON backup, bounded consistent database snapshot and Files export |
| [PRs #16–20](PROJECT_STATUS.md) | Atomic reading state, durable deployment identity, exact chapter URLs, stale-mutation rejection and shared operation coordination needed before safe restore |

The corrected decoder accepts one complete gzip member with integrity and
size checks. It does not add zlib/zstd backup support. Kotlin reference
serializer fixtures and independent gzip fixtures demonstrate deterministic
format behavior; they are not a user backup exported by a running Android app.
The pinned [decoder contract](https://github.com/taizaki69/Kami/blob/8b7d98046dd04cd1ba99d2e27ee856629876f64e/docs/BACKUP_COMPATIBILITY.md)
and [fixture provenance](https://github.com/taizaki69/Kami/blob/8b7d98046dd04cd1ba99d2e27ee856629876f64e/Tests/backups/README.md)
record the exact supported fields and limits.

Native export is a separate format; it does not establish Mihon import or
`.tachibk` export. Its [format and scope](https://github.com/taizaki69/Kami/blob/7bcbe7cb94c80527dd371a746fe591308f91aa49/docs/NATIVE_BACKUPS.md)
include history, hidden chapters and discovery state. Neither format has a
completed product restoration flow at the reviewed continuation head.

## Restore requirements

1. Decode one bounded immutable input and retain coverage information.
2. Produce a reviewable preview bound to the input, target state and policy;
   explicitly report unknown sources, deployment conflicts and unsupported data.
3. Match exact source and UTF-8 URL identities. Fuzzy title/chapter-number
   matching belongs to a separate, user-selected migration flow.
4. Preserve read/bookmark/progress/history and category membership. Validate
   Mihon category-order references and timestamp units before mapping.
5. Verify MangaDex source IDs and URL shapes before mapping extension URLs to
   native UUIDs. Preserve FoolSlide deployment identity; a source label alone
   cannot establish that identity.
6. Revalidate after obtaining exclusive access, merge transactionally and
   publish the new library generation only after successful commit. Rollback
   must preserve the old data and epoch.
7. Never import APK execution authority, enable extensions or establish signer
   trust from backup metadata. Report unavailable sources without silently
   discarding their library records.

Acceptance criteria and regression cases are in [TODO.md](../TODO.md).
