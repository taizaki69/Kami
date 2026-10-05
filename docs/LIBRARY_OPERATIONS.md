# Shared library operations

One MainActor `LibraryOperationCoordinator` belongs to the shared AppModel,
which is created outside WindowGroup. Every scene uses that same coordinator.
It complements the database-issued reading targets and mutation contexts; it
does not replace SQLite transaction validation or grant extension/file authority.

## Ownership and exclusion

`start(expected:)` reserves synchronously before creating its Task. A lease
can instead remain open across idle time, such as an open reader or pending
signer confirmation. Its `start` and `withScope` register each worker before
suspension. Closing a lease prevents more work; registered workers retain
ownership until they return or throw, including cooperative cancellation.
Cancelling an observer alone does not release or cancel an owned Core worker.
AppModel's observer explicitly forwards cancellation and awaits worker drainage.
ReadingStateWriter deliberately keeps its worker independent of view observers.

Limits are 256 operations per coordinator and 128 workers per lease. Failed
admission changes no ownership. Run cancellation and reader/prompt cleanup use
their existing lease so a full global operation set cannot prevent drainage.
Each owner must close its lifetime; the coordinator has no deinit fallback.
Private TaskLocal context permits scope validation but is not a reservation for
an independent Task. An independent worker must register its own lifetime.

Exclusive acquisition fails while any ordinary operation is registered. While
exclusive, new operations fail before their bodies execute. An exclusive token
belongs to one coordinator and is consumed by finish; foreign/repeated tokens
cannot release another operation. Abort keeps the presentation generation.
After a successful database commit, `publishCommittedChange` changes it
once while exclusion is still held, then `finishExclusive` releases exclusion.
Cancellation after publication never restores the previous generation. These
methods do not implement a database commit or prove that one occurred.

## Integrated producers

| Producer | Ownership and stale-data boundary |
| --- | --- |
| Startup and reloads | Bootstrap, recovery, repository fetches and list/count refreshes run in an owned scope; nested work remains awaited. |
| Categories and membership | Reservation precedes Task creation. Drafts/IDs keep their database context; stale contexts fail in SQLite. |
| Detail, Browse and persisted reader opening | Frozen presentation generation precedes lifecycle work and the first reading-save wait. Source results retain their existing context and source revision. |
| History, Updates and Downloads routes | The route contains the presentation generation captured with its row; a reused row ID cannot adopt a new generation at destination creation. |
| Reading saves and retries | The serial writer reserves before its first worker starts and retains ownership across all queued writes. Rejection is a finite retained failure; retry keeps the original target. |
| Open readers | Parent and page-session lifetimes remain active while idle. The child owns cleanup for a different offline chapter reached by next/previous navigation, independent of parent disappearance order. Cleanup closes file leases and awaits a finite save frontier before refreshing downloads. |
| Library scans | A separate lifetime covers startup, the entire progress stream, cancellation/drain and final refreshes, even when the initiating screen leaves. |
| Downloads | Enqueue/retry/control work is scoped; the queue has its own lifetime until its stream and final refreshes finish. Pause/cancel borrow the run lifetime, including scene backgrounding. ID-only controls carry the displayed generation. |
| Extension changes | Repository writes, install/enable/settings, detached source construction and failure cleanup remain owned. The detached construction is awaited. |
| Signer confirmation | A lifetime spans preparation through explicit confirmation or cancellation. A second preparation is cancelled without replacing the pending prompt. Confirmation/cancellation borrow the existing lifetime. |
| Backup export and preview | Snapshot/encoding and bounded Files acquisition are awaited by an owned operation, including cancellation and view disappearance. Export and review consume immutable bytes. |
| Native restore | `startLibraryRestore` reserves exclusion synchronously and owns the detached database worker through cancellation/drain. Only committed success publishes a generation; dropping a UI observer does not cancel the operation. |

AppModel checks current scope before its asynchronous persistence/presentation
entry points. Direct Store reads in views execute inside lifecycle scopes.
Image byte/cache tasks and result observers do not write library state; page
publication keeps existing session/load/source guards. Offline close is awaited
by reader cleanup; any duplicate fallback close is idempotent. Name-field focus,
reader preferences and Files export completion are presentation-only callbacks.

## Scene publication

An opaque generation is captured with route values and ID-only actions.
AppModel clears library/update/download rows, cursors, counts, progress and
errors before exposing a new generation. Every root TabView has that shared
identity and disables interactions during exclusion. Persistent list lifecycle
refreshes also observe the exclusive state, so a new root created during
publication reloads once exclusion finishes. Frozen readers/details and old
callbacks still fail generation checks; root identity is not the sole guard.
Retained reading failures preserve their original database targets rather than
silently discarding unsaved intent or renewing it against a replaced library.

## Native restore integration

`startLibraryRestore` uses the shared exclusion boundary around the complete
[native restore](NATIVE_BACKUPS.md). Its Store transaction independently rejects
active durable scans/jobs, revalidates preview dependencies under BEGIN IMMEDIATE,
merges exact identities and rotates the durable epoch before COMMIT. Failed or
cancelled transactions release exclusion without publishing. Successful COMMIT
is never reclassified as cancellation; publication occurs while still exclusive.
AppModel keeps the operation handle across sheet dismissal and shows a finite
completion/failure notice. A failed preview must be reviewed again.

Actual SQLite/coordinator integration tests cover idle readers, queued work,
rollback, queued cancellation, observer cancellation and cancellation during
committed publication. See the [restore verification record](VERIFICATION-2026-10-04-NATIVE-RESTORE.md).

Portable continuation-based tests verify the coordinator and writer boundary;
Apple builds verify integration compilation. They do not prove physical-device
or interactive multiwindow behavior. See the
[verification record](VERIFICATION-2026-10-04-LIBRARY-OPERATIONS.md).
