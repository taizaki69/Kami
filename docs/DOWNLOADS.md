# Downloads and offline reading

The download manager saves selected library chapters in an explicitly started
foreground queue. One chapter and one page transfer at a time. Queue state,
finished chapters and failures survive relaunch; startup performs local recovery
without starting network requests. Interrupted chapters retry from page zero
with a fresh page list and current source registration.

Starting or retrying requires the source to be enabled and admitted under its
current configuration. Downloading does not enable sources or grant trust.
A finished local chapter can be read when its extension is disabled or absent.
Removing a manga from the library pauses pending work and retains completed
downloads. Deleting a download preserves library metadata, chapter progress,
bookmarks and history.

## Completion and recovery

Schema 5 replaces the former inert `download` table with a durable job,
ordered page receipts and a cleanup ledger. Old rows, including those previously
labelled finished, migrate to paused/unverified: they never proved saved files.
Each attempt has a fresh UUID and a revision checked against the job, library
membership and source configuration. Disabling a source, replacing its facade,
changing its settings or removing library membership invalidates pending work.
Completed data has a separate lifetime.

The filesystem and SQLite use an explicit publication sequence:

1. Reserve capacity, obtain the exact source image request, validate its bytes
   with ImageIO, write and flush a generated page file, then commit its receipt.
2. Verify all ordered pages and write a canonical manifest. Prepare the exact
   manifest digest and receipts in SQLite while the attempt is still current.
3. Rename the staged directory and flush the parent directories. Mark the job
   finished only through the final SQLite attempt/configuration check.

Recovery pauses interrupted attempts and cleans partial or orphan generations.
Files renamed before a missing final database commit are discarded, never
promoted merely because they exist. File and directory flushes are requested;
fixtures simulate protocol interruption and reopening, not physical power loss.

An offline open requires a finished database generation, matching canonical
manifest, matching ordered receipts and the complete generated file set.
Each page read checks length and SHA-256 before decoding. Missing or corrupt
local content reports an error. Reading online requires a separate explicit
action; local retry never contacts a source. A read lease keeps its immutable
bundle alive until the reader closes. Deletion blocks new leases immediately,
defers file removal until the last lease closes, then acknowledges cleanup.

## Limits and source requests

The production defaults are hard upper bounds; fixtures may use smaller limits:

| Resource | Limit |
|---|---|
| Chapter page count | 1–2,048, ordered zero-based indices |
| Compressed page | 32 MiB |
| Chapter image bytes | 512 MiB |
| Managed file bytes | 2 GiB, including staging, manifests and orphans |
| Free-space floor | 256 MiB, checked before reservation |
| Manifest | 1 MiB |
| Persisted jobs | 10,000 |
| Managed files | 100,000, with page and manifest slots reserved |
| Simultaneous local read leases | 64 |
| Page URL metadata | 4 KiB per URL and 8 MiB per page list |

Reservations include a maximum-sized next page and manifest before transfer.
Free-space checks are advisory: later filesystem write failures still stop the
attempt. Completed user downloads are not automatically evicted. SQLite's page
byte totals are separate from physical file accounting used to enforce quota.
Compressed-byte and decoded-dimension limits are not a whole-process memory
or device-performance guarantee.

Source requests keep their original headers, transport policy, opaque executor
and revocable registration scope. The download engine uses a dedicated image
pipeline with caching disabled, so cancelling it cannot clear the reader's
image flights. Cancellation invalidates the durable attempt before cancelling
and draining execution. The exact interpreted image-request table fails closed
at its 4,096-handle limit instead of dropping the opaque executor and falling
back to a plain request.

Only internal UUID directories and ordinal filenames reach file operations.
Files are accessed relative to owned directory descriptors; symlinks, hardlinks,
special files and unexpected cleanup entries are rejected. URLs, source titles,
HTTP headers, cookies, signed requests and executor handles are never used as
durable file paths or replay capabilities.

## Verification and remaining scope

Filesystem fixtures exercise actual writes, reopening, corruption, missing
pages, quota, cancellation and deferred deletion. Their injected validator tests
storage mechanics only. Apple-hosted tests exercise the production ImageIO
decoder; unsupported platforms fail closed. Database and coordinator fixtures
use deterministic source responses with no live manga sites.

See the dated [verification record](VERIFICATION-2026-10-03.md) and implementation
PR for exact-commit suite/build evidence. Physical-device interaction, long
chapter memory/performance, background transfer, automatic downloads, byte-range
resume, local CBZ import and broader image transforms remain separate work.
This increment admits no additional APK or source profile.
