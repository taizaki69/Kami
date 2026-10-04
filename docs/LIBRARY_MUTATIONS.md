# Library mutation contexts

Category, library membership and source-result writes require the context
issued with the stored values that started the operation. A queued category
deletion or a suspended provider response must not adopt a newer database
generation and apply old IDs or metadata to it.

`LibraryMutationContext` contains the issuing LibraryStore UUID and the
durable schema-6 data epoch. It is opaque, immutable, Sendable and Equatable,
with no public constructor or Codable representation. Ordinary reading,
metadata, category and membership changes do not rotate the epoch. Reopening
the database preserves the epoch but creates a different store owner, so a
context from another instance is rejected.

## Snapshot and write contract

LibraryStore pairs the context with these values in the same transaction:

- `librarySnapshot()` includes the library, categories and memberships.
  The public value-only `LibrarySnapshot` initializer has a nil context and
  cannot authorize changes.
- `MangaReadingSnapshot` includes the context alongside its stricter per-chapter
  reading targets. `SourceMangaSnapshot` also carries a context when a new manga
  has no stored row. Source snapshots use the bounded reading snapshot decoder.
- `beginLibraryUpdateScan()` includes the context with the durable scan and
  captured manga. All source workers keep that context for the run.

The required context argument applies to category create/rename/reorder/delete,
assignment replacement/deltas, `setLibrary`, `persistSourceUpdate` and
`recordLibraryUpdateSuccess`. `LibraryService.refresh` requires the caller's
context and rereads stored values only after validating it. Raw `upsert` and
`replaceChapters` are internal helpers; App clients cannot use them to bypass
the guarded source publication APIs. Fresh-action convenience overloads exist
only in the test target, not in KamiCore.

Each guarded write acquires `BEGIN IMMEDIATE`, checks cancellation, owner and
the stored epoch, performs the existing domain checks/writes, then checks
cancellation before COMMIT. Missing or malformed epoch state fails without
repairing it. The epoch reader validates singleton/type/length before loading
the 16-byte value. Even empty assignment/delete operations validate their
context. A write failure rolls the transaction back; SQLite failures become
the finite `LibraryMutationError.storageUnavailable`. Successful commits have
no later cancellation check that could falsely report rollback.

Source execution checks validate the retained context before provider work.
Final publication repeats that validation inside the write transaction along
with existing source, exact URL and authenticated configuration checks. A
source context does not grant APK trust, source execution or a file lease.
The scan service reports a library change and drains its worker when a
context expires, instead of attributing the failure to the website.

## App capture

Library rows and their mutation contexts come from one captured snapshot,
including lazy row closures. Selection, category names, assignments and delete
confirmations retain that context before their Task is created. Text and
assignment drafts are also copied before scheduling. An assignment sheet
cannot reset its draft into a different generation; it asks the user to reopen.

Detail keeps its original source snapshot through provider work and validates
it again when rereading the saved result. It publishes the returned metadata
and reading snapshot together. Membership actions retain the displayed reading
snapshot. Online page checks use the reader's frozen context in addition to
its existing chapter target and source lifetime checks.

## Remaining restore boundary

This is a generation guard, not a complete restore barrier or a per-row
concurrent-edit version. Same-generation actions retain their existing merge
and last-write behavior. No schema migration, epoch rotation API, restore
preview or merge is added.

Restore still requires shared synchronous intent registration before scheduling,
exclusive acquisition until workers drain, and presentation invalidation across
all scenes. The inventory includes reading saves, initial Detail opening,
scan/download ownership, queued downloads, settings, installation/trust and
repository writes. For example, initial Detail opening still captures its
first snapshot after waiting for pending reading saves; a queued opening must
participate in the future app barrier before restore can be enabled. Scan
completion/skip/failure rows keep their existing operational lifecycle.

The eventual restore transaction must revalidate preview dependencies and
active ownership, merge conservatively and rotate the epoch only as part of
a successful commit. These contexts are one prerequisite, not evidence that
restoration or all stale-scene presentation is safe.

See the [verification record](VERIFICATION-2026-10-04-LIBRARY-MUTATIONS.md).
