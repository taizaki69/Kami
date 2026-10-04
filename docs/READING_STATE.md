# Reading state

Reader progress is one persistence operation. Page position, the history entry
and the read flag set at the last page commit in a single SQLite write
transaction. A failed history insert or cancellation before commit rolls back
the complete operation. Once commit succeeds, Core returns the saved result
without a post-commit cancellation error that would imply rollback.

Ordinary reading may move backwards. Reaching the end sets the read flag;
other page movement preserves it. Bookmark state and existing history duration
are retained. A new history entry starts with duration zero. Manual read/unread
changes only the read flag and returns the actual stored chapter.

## Captured reading targets

Schema 6 seeds one durable random 16-byte data epoch. Ordinary reads, app
reopens, progress updates and metadata refreshes do not rotate it. A separate
UUID identifies each LibraryStore instance. Neither value is exported in a
native backup or derived from imported data.

`MangaReadingSnapshot` reads manga, current/downloaded chapters, an optional
requested hidden chapter, the epoch and opaque `ChapterWriteTarget` values in
one transaction. Source ID, parent/child row IDs and both URL byte sequences
are part of a target. The target and epoch have no public constructor or
Codable representation. The selected chapter set includes hidden chapters
opened through History and permits nonlibrary manga and unavailable sources;
reading state does not grant source execution or access to downloaded files.

`commitReadingProgress` and `setChapterRead` acquire `BEGIN IMMEDIATE`, reread
the durable epoch and validate the store owner and exact identities before
writing. A foreign store, changed epoch, rebound parent/child, malformed state
or missing row rejects the operation. URL comparisons preserve UTF-8 bytes;
canonically equivalent Unicode spellings are not interchangeable. The old
public ID-only page/history/read mutation APIs have been removed.

`validateReadingTarget` returns current chapter state without renewing a
target. `refreshReadingSnapshot(validating:)` may refresh lists only after
validating the original target. Explicit initial opening uses
`readingSnapshot(sourceID:mangaURL:requestedChapterID:)`; retained readers must
not call it to adopt a newer epoch after a suspended operation.

## Reader behavior

Detail, History, Updates and Downloads pass the captured snapshot into the
reader before provider/page work begins. A reader freezes that snapshot and
keeps its targets through retry, Read online and previous/next navigation.
Each asynchronous result must still match the selected chapter and load
generation. Selecting a neighbour invalidates the previous generation before
scheduling the next load.

Online page loading validates the target before requesting pages and after
suspended provider work. Offline opening additionally retains the independent
download manifest/receipt checks, validates the target before preparation and
after acquiring the lease, and closes rejected leases. A file lease grants no
database mutation authority.

The reader publishes saved chapter values only after the atomic write succeeds.
AppModel owns a serial reading-write queue. The view enqueues the complete
intent synchronously before starting a result observer; cancelling that observer
on Next, Read online or dismissal cannot cancel the captured final save. Manual
read actions use the same queue. Pending updates for the same target may
coalesce to the latest position/time while retaining a reached-end event.
Before clearing pages or closing, the view captures a page change whose
SwiftUI observation has not run yet; a page already queued is not submitted
again merely because the reader closes.
An opening snapshot waits for the already queued writes using a captured finite
queue boundary, so another reader cannot keep extending that wait.

A shared save-error banner keeps failed intents visible after their originating
view closes and allows retry with the original target. A newer intent prevents
an older failed retry from overwriting its state. Saving only a read flag does
not erase evidence that an earlier page/history save failed; partial supersession
remains visible until handled. An expired or rebound session requires closing
and reopening.
Manual read/unread captures its intended flag and target before scheduling,
prevents a duplicate pending action for that row and changes the checkmark only
after a successful result for the same view generation.

## Bounds and limits

Reading snapshots select at most 20,000 current/downloaded/requested chapters
per manga. Stored scalar types, row counts and text lengths are checked before
materialization. URL fields are limited to 4 KiB, metadata to 8 KiB and manga
description to 256 KiB. Aggregate stored text is bounded to 64 MiB and decoded
strings to 32 MiB. Text is extracted as bytes and decoded strictly; malformed
UTF-8, embedded NUL, invalid booleans/numeric state and nonfinite chapter
numbers fail rather than silently becoming defaults.
The writer permits one active operation and 128 pending intents, retaining at
most 16 failures. Queue overflow is an explicit failed save. Failure overflow
keeps a bounded recent set and reports that earlier failures were omitted.
That notice survives success or dismissal of the retained failures until the
user explicitly acknowledges it.
These are in-memory intents; the queue does not promise survival across process
termination or background execution.

These are Core and App prerequisites for later restore work. Restore remains
unavailable. The next steps must add durable Foo content binding, shared scene
invalidation and synchronous operation-intent barriers, epoch checks for source
results/category/membership and other queued writes, immutable preview state
validation and an atomic conservative merge. Epoch rotation must be part of
that successful restore transaction; this increment exposes no standalone
rotation or restore operation. An epoch is not a general same-generation
concurrent-edit conflict detector or a complete restore preview token.

The [dated verification record](VERIFICATION-2026-10-04-READING-STATE.md) and
implementation PR distinguish deterministic
SQLite coverage and Apple compilation from physical-device interaction. No
Files restore, offline device interaction or memory/performance claim follows
from the unit tests alone.
