# Reviewed Mihon library import

Library → Library options → Library backups → **Choose a Mihon backup** reads
a downloaded gzip `.tachibk` or raw protobuf file through Files. It uses the
[bounded Mihon decoder](BACKUP_COMPATIBILITY.md), then maps demonstrated source
identities into the [native restore transaction](NATIVE_BACKUPS.md). Native
Kami JSON keeps its separate picker action and validation contract.

## Demonstrated mapping

Adapter version 1 supports **English MangaDex source 2499283573021220255** and
only these complete ASCII persisted forms:

```text
/manga/U   -> U
/chapter/U -> U
U = [0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}
```

No whitespace trimming, URL decoding, case folding, substring UUID search or
network migration occurs. Other language/source IDs, bare UUIDs in Mihon input,
absolute/display links, slugs, extra path segments, query/fragment strings,
old numeric IDs and unsupported UUID forms are excluded with counts. Names
and backup source descriptions never establish source identity or authority.

The mapping follows the immutable Keiyoushi source revision
`6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a`:

- The [build declaration](https://github.com/keiyoushi/extensions-source/blob/6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a/src/all/mangadex/build.gradle.kts)
  declares MangaDex languages and no overriding ID/version ID.
- [ExtensionPlugin](https://github.com/keiyoushi/extensions-source/blob/6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a/gradle/build-logic/src/main/kotlin/ExtensionPlugin.kt)
  computes `mangadex/en/1` by MD5, first eight bytes big endian with sign cleared.
  [SourceProcessor](https://github.com/keiyoushi/extensions-source/blob/6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a/compiler/src/main/kotlin/keiyoushi/processor/SourceProcessor.kt)
  injects that ID into the concrete source constructor.
- [MangaDexHelper](https://github.com/keiyoushi/extensions-source/blob/6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a/src/all/mangadex/src/eu/kanade/tachiyomi/extension/all/mangadex/MangaDexHelper.kt)
  constructs the stored manga/chapter paths.
  [MDConstants](https://github.com/keiyoushi/extensions-source/blob/6512a2e94c71df63d6e7d60d2dd01d3b79ae0a5a/src/all/mangadex/src/eu/kanade/tachiyomi/extension/all/mangadex/MDConstants.kt)
  supplies the intentionally strict UUID grammar used here.

The same construction was traced at corpus source pin
`42771052f3e43b09a04d4b3f9073039690607476`; the published index at
`94bfcdd85c4e3ef3ed4d742faf2d91edd0b9fe39` independently lists the English ID.
These are source/identity facts, not binary execution or broad interoperability
claims. A backup cannot prove chapter parentage, language or online existence.

## Explicit review and loss reporting

The review shows total/supported manga, excluded manga/chapter/history counts,
unsupported-field occurrences by feature/scope, source IDs and finite exclusion
reasons. A separate acknowledgement is required even when all mapped records
fit: **Import only the supported data reviewed above**. This creates a new
store-issued preview from the same immutable input bytes. A file with no
supported manga cannot commit.

Excluded records and unsupported messages are not persisted in Kami. The UI
asks the user to keep the original backup. This first adapter supplies no inert
archive database and never places an unresolved MangaDex identity into native
operational rows. Full app/source preferences, tracking, repositories, reader
settings and other unsupported fields remain outside the imported domain.
Their decoder coverage is not silently treated as complete import.

Duplicate manga and chapter records keep the first metadata, OR favorite/read/
bookmark state, and retain the greater page/history values. Durations are never
summed. Category references use upstream **order**, not ID. Names are validated
and trimmed using Kami's category rules; ambiguous orders/names fail the preview.
Missing category references and memberships on nonlibrary manga are reported
and excluded. Favorite=false remains outside the library.

A chapter UUID claimed by multiple supported manga is excluded, including a
conflict with an existing native row. History resolves only to an exact chapter
under the same mapped manga; it can reuse an existing stored chapter when the
backup omits chapter records. Unmatched/ambiguous history is reported; zero
last-read represents upstream removed history and is excluded. No title, number
or scanlator matching invents a chapter relation.

## Units and discovery

| Field | Mapping |
| --- | --- |
| Manga date added | Upstream milliseconds → native whole seconds by integer division. When absent/zero on a favorite, use historical favoriteModifiedAt seconds directly. |
| History last read | Positive upstream milliseconds → whole seconds, matching Kami's writer and History display. |
| Chapter upload/fetch dates | Preserve upstream milliseconds. Native chapter upload data already uses milliseconds; fetch is retained archival state. |
| History duration | Preserve milliseconds; Kami currently retains this scalar without a running duration clock. |
| Source order/page progress/category flags and order | Preserve signed Int64 precision; invalid negative progress/dates/duration fail. |

The review counts timestamp rounding and trimmed category names. The fallback
never multiplies historical seconds, so large Int64 values do not overflow.
The [Mihon manga model](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupManga.kt)
defines the mixed-unit fallback. The
[history model](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupHistory.kt)
uses a millisecond Date; the
[reader timer](https://github.com/mihonapp/mihon/blob/7aacaa349019ff42b8b05403d8beebe94c8f6dfc/app/src/main/java/eu/kanade/tachiyomi/ui/reader/ReaderViewModel.kt)
supplies duration from millisecond clock differences.

Imported chapter IDs enter silent discovery knowledge, without establishing a
live source baseline or creating Updates. The first live catalog refresh still
establishes its baseline. Native MangaDex uses representative aggregate IDs;
a later refresh may hide alternate imported editions, preserving their rows,
progress, bookmarks, history and discovery knowledge.

## Transaction and limits

Files acquisition uses the existing opened-descriptor regular-file check and
32 MiB input ceiling for Mihon. Decode keeps its hard 64 MiB expanded-payload,
record, field and string bounds. Mapping and the resulting union also satisfy
the lower-only native domain policy. No target rows are changed during preview.

The preview binds the original file SHA-256, adapter version/report, explicit
acknowledgement and conservative plan to one Store, durable epoch, dependency
digest and SQLite change stamp. Mapping checks target identities within that
same consistent read snapshot. Commit uses the existing exclusive coordinator
and BEGIN IMMEDIATE revalidation/rollback/epoch publication. The public DTO and
report cannot construct a restore capability. Import performs no source requests,
installs, settings writes, download writes or trust changes.

## Evidence and remaining scope

See [the dated verification](VERIFICATION-2026-10-04-MIHON-IMPORT.md) for package
results and the implementation PR for exact-head Apple builds and artifacts.
The sixth [Kotlin reference fixture](../Tests/backups/README.md) supplies a
synthetic positive mapping case; the previous five fixtures retain their bytes.
No fixture is a personal backup exported by a running Android app.

Other measured source adapters, more MangaDex languages/URL forms, source
migration and unsupported-field support remain open. Files-provider interaction,
physical multiwindow behavior and large-library device memory/performance need
separate evidence. This feature does not establish general Mihon/Tachiyomi fork
compatibility or identical catalog/settings behavior.
