# Native library backups

## Product scope

Library → Library options → Library backups prepares a point-in-time copy,
shows its counts and size, and offers **Save to Files**. Preparation can be
cancelled; leaving the sheet cancels its task and prevents late results from
replacing the screen state. Success is shown only after the system exporter
reports a saved file. The export is unavailable if the persistent database
could not be opened; the app's temporary fallback library cannot be exported.

The same screen provides **Choose a Kami backup**, an immutable preview with
counts and source conflicts, and explicit restore. Both export and restore
require durable storage. This flow accepts native JSON v1; Mihon decoding has a
separate [compatibility contract](BACKUP_COMPATIBILITY.md) and a
[measured import flow](MIHON_IMPORT.md). Source migration and `.tachibk` export
remain pending.

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
Snapshot keys use a padded ordinal, retaining the saved category sequence when
sort orders are equal; memberships follow that same category ordering.

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

The known Foo ID cannot use `sourceIdentity`. Export reads its
[durable content binding](SOURCE_CONTENT_BINDING.md), independently of current
installation settings. Migration 7 infers that binding once from bounded,
valid legacy identity and preference provenance; unproven existing content
receives an explicit `unresolved` binding. Subsequent preference corruption,
disablement, re-admission or missing APK bytes cannot downgrade a known binding.
A missing/malformed binding with Foo manga fails export rather than guessing.
Source descriptions accompany archived manga; configuring an otherwise empty
source does not add its settings to a library backup. Other source IDs cannot
claim this measured Foo contract. Restore reports unavailable sources separately
from content conflicts; neither a label nor a numeric source ID enables execution.

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
the codec runs away from the main actor. Native export itself adds no schema
migration; the separate reader-state foundation introduces its own data epoch.

## Review and atomic restore

Files input is opened once with security-scoped access, checked as a regular
file on the opened descriptor, and read in cancellable bounded chunks. Links,
folders and oversized files fail. Review-again uses those immutable bytes; it
does not reopen a provider URL. The preview reports new/existing manga and
chapters, new categories, history entries, unavailable sources and content
conflicts. Excluding conflicting sources requires an explicit toggle and a new
preview before the restore button can proceed.

The preview is non-Codable and issued only by its LibraryStore. It retains the
validated merge plan, input SHA-256, store owner, durable epoch, policy, bounded
domain/identity/configuration digest and SQLite change stamp. Another store,
changed settings/identities, remove/re-add, save/revert and concurrent database
writes invalidate it. Cancellation checks span decoding, planning and writes.
The target and final union must satisfy the same domain limits; oversized
unions fail rather than truncate. Dependency records additionally have row,
column and cumulative byte bounds and strict SQLite storage-type validation.

The app reserves its shared exclusive operation synchronously. Open readers,
pending writes and active source operations must finish first. Commit also
rejects running durable scans and working/prepared downloads without recovering
or cancelling their owners. Under `BEGIN IMMEDIATE`, the Store revalidates the
approved state, writes the plan and rotates its durable epoch atomically. A
failure or pre-commit cancellation rolls back all effects. Successful COMMIT
causes shared scene invalidation while exclusion is still held, even if a late
cancellation arrives; an old preview cannot be reused.

| Data | Conservative merge rule |
| --- | --- |
| Manga | Match exact source ID and UTF-8 URL; keep existing metadata, dates and initialization; OR library membership. New rows retain archive scalars. |
| Categories | Match existing domain name rules, retain saved order/flags, append new names after the largest saved order; reject overflow. |
| Membership | Union mapped category references. |
| Chapters | Match exact UTF-8 URL under the manga; preserve saved metadata/currentness, OR read/bookmark, take the greater page position. Archive-only chapters under an established catalog remain hidden. |
| History | Greater last-read timestamp and duration independently; durations are never added. |
| Discovery | Keep saved baseline/known records. New imported knowledge has no detected timestamp and creates no new Updates. |
| Downloads and authority | Preserve local jobs/files/receipts, repository trust, installations and executable settings. Never import them. |

Repeated imports are idempotent for domain data; each successful restore still
rotates the epoch to invalidate retained targets. Native archive source labels
are descriptive and are not persisted as runtime configuration.

FoolSlide manga require the same exact deployment URL as the saved content
binding. Different or unresolvable populated namespaces conflict and are either
blocked or explicitly excluded. An empty target may adopt a known deployment
as content provenance only; an unresolved Foo namespace stays inert. An
unknown non-Foo source with unresolved provenance cannot establish an inert
namespace and is reported as a conflict. These rules do not enable a source
or grant new request/signing authority.

## Verification and remaining work

The [dated verification record](VERIFICATION-2026-10-04-NATIVE-BACKUPS.md) and
implementation PR record package results and Apple compilation for the exact
published commit. Synthetic codec and temporary SQLite fixtures cover field
fidelity, precision, hidden rows, history beyond the UI limit, cancellation,
malformed storage and budget boundaries. They are not backups from an installed
iOS app and do not establish Files interaction or device memory/performance.

The [native restore verification](VERIFICATION-2026-10-04-NATIVE-RESTORE.md)
records persistence, file and operation-lifetime regressions. Files-provider
interaction, physical multiwindow behavior and large-library device memory
remain unmeasured. The [Mihon import flow](MIHON_IMPORT.md) adds a measured
source/URL adapter and coverage review; decoding a DTO alone still does not
authorize native restoration.
