# Native library backups

## Product scope

Library → Library options → Library backups prepares a point-in-time copy,
shows its counts and size, and offers **Save to Files**. Preparation can be
cancelled; leaving the sheet cancels its task and prevents late results from
replacing the screen state. Success is shown only after the system exporter
reports a saved file. The export is unavailable if the persistent database
could not be opened; the app's temporary fallback library cannot be exported.

The screen explicitly states that **restoration is unavailable in this
version**. This increment supplies native export and a validating codec.
It does not supply restore preview, merging, source migration or `.tachibk`
export. Mihon decoding has a separate [compatibility contract](BACKUP_COMPATIBILITY.md).

The `.kamibackup` file is uncompressed UTF-8 JSON. It contains reading history
and descriptive source URLs. It includes all saved domain rows, not just the
current library filter or the 200 entries shown in History:

| Record | Included data |
| --- | --- |
| Manga | Source ID and exact URL, metadata/alternate titles/genres, library membership, added/updated/fetched timestamps, update strategy and initialization |
| Categories | Empty categories too; names, order, flags and membership through archive-local keys |
| Chapters | Hidden and current rows, source order, URL/name/scanlator/number, fetched/uploaded dates, read/bookmark/progress |
| History | Every stored chapter reference, last-read value and read duration |
| Discoveries | Missing versus established baseline, known URLs without a physical chapter row, first-seen and optional detected timestamps |
| Source description | Source ID, descriptive labels and the saved content namespace when it can be established |

Downloaded image files and queue state, update-run ledgers, extension APKs,
signing trust, repositories, executable preferences, cookies and app/reader
settings are excluded. Archive source metadata cannot authorize installation,
activation or requests.

## Format v1

The root declares `format: "kami.library"`, `version: 1`,
`scope: "allStoredDomainRows"`, a UUID `exportID` and `exportedAt` as whole Unix
seconds. Required arrays are `sources`, `categories` and `manga`. Every Int64
value is a canonical decimal **JSON string**, preserving negative IDs and
values above 2^53 without a floating-point conversion. `version`, `status` and
the finite Double chapter number are JSON numbers. The unknown chapter number
sentinel remains `-1`.

Persisted date fields keep their existing field-specific units. Export performs
no heuristic date conversion. Optional values are absent when missing; explicit
`null`, missing required fields, unknown enum values and unknown schema keys
are rejected. Negative dates, reading durations and page positions are invalid;
signed source IDs, category flags/order and chapter source order are preserved.

The writer uses stable object-key and identity-row ordering. Source IDs sort
numerically, manga sort by source ID/exact UTF-8 URL, categories by order/key,
and chapters by source order/URL. History, known URLs and memberships have
stable byte ordering. Alternate titles and genres retain their saved sequence.
Categories use archive-local keys instead of SQLite row IDs.

Source/URL identities and DTO equality compare exact UTF-8 bytes, matching
SQLite BINARY identity; canonically equivalent Unicode URL spellings remain
different rows. Duplicate identities, ambiguous category names, missing
references, cross-manga history and nonlibrary category memberships are rejected.
The lexical pass rejects duplicate/escaped-equivalent JSON keys and Unicode
key aliases before Foundation decoding can collapse them. Schema names must
match the declared UTF-8 spelling.

`contentBinding` has one of three meanings:

- `sourceIdentity`: the source ID is the descriptive namespace.
- `deployment`: the known configurable FoolSlide source also carries its exact
  saved HTTPS deployment URL.
- `unresolved`: a content namespace could not be established.

The known Foo ID cannot use `sourceIdentity`. Export derives its descriptive
deployment only from bounded, valid persisted installation identity and matching
preference provenance. It works with a disabled installation or missing APK;
it does not load or authenticate that APK. Invalid or absent provenance yields
`unresolved` and is not rewritten. Other source IDs cannot claim this measured
Foo deployment contract. A future restore must separately establish operational
source availability and resolve conflicting or unresolved namespaces.

## Bounds and consistent reads

`LibraryBackupPolicy` is immutable. Injected policies may lower every ceiling;
they cannot raise them. The writer checks remaining output capacity before
appending bytes, including JSON escape expansion.

| Resource | Default and hard maximum |
| --- | ---: |
| Input / output JSON | 64 MiB each |
| JSON values / depth | 4,000,000 / 32 |
| Decoded JSON string bytes, including keys | 64 MiB |
| Keys per object / elements per array | 64 / 100,000 |
| Manga / source records / categories | 10,000 / 10,000 / 1,000 |
| Chapters / history / known URLs / memberships | 100,000 each |
| Chapters per manga | 20,000 |
| Alternate titles / genres per manga | 256 each |
| URL / source or category label / metadata field | 4 KiB / 1 KiB / 8 KiB |
| Description / total domain string bytes | 256 KiB / 32 MiB |

`LibraryStore.exportBackupSnapshot` uses one synchronous read transaction.
Counts, stored types, per-column byte lengths and relation checks happen before
rows are materialized. Text is read as bounded BLOB bytes and decoded strictly,
so an embedded NUL or invalid UTF-8 cannot silently truncate or replace text.
Stored JSON arrays also pass value/string/array limits before allocation.
Numeric-affinity columns used to describe Foo settings must actually contain
SQLite integers; an oversized TEXT/BLOB in an INTEGER column cannot bypass
the preflight. Cancellation is checked between bounded queries and during
model construction, JSON traversal, sorting and encoding.

Malformed, ambiguous or oversized library data fails export as a whole.
An export neither repairs corrupt rows nor cancels/changes ongoing update or
download work. The database actor serializes the snapshot with normal writes;
the codec runs away from the main actor. No database migration is needed.

## Verification and remaining work

The [dated verification record](VERIFICATION-2026-10-04-NATIVE-BACKUPS.md) and
implementation PR record package results and Apple compilation for the exact
published commit. Synthetic codec and temporary SQLite fixtures cover field
fidelity, precision, hidden rows, history beyond the UI limit, cancellation,
malformed storage and budget boundaries. They are not backups from an installed
iOS app and do not establish Files interaction or device memory/performance.

Restoration still requires an immutable preview tied to input/store state, an
atomic conservative merge, content-binding conflict handling and protection
against stale readers/source operations. Mihon import additionally needs explicit
URL/source adapters and coverage reporting. None of these operations is enabled
by merely decoding a native document.
