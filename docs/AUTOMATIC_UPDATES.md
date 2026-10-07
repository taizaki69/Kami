# Automatic library updates

In **Updates → Automatic updates**, enable automatic checks and choose a minimum
interval of 6, 12 or 24 hours, then Save. The default is off. The first request
is eligible after 15 minutes. The panel shows whether a request was accepted,
an earliest eligible date, system restrictions, scheduling/storage failures and
the last automatic attempt. Saving off cancels the pending request and an owned
automatic check; results already committed remain in Updates. Manual checks
remain available and cannot overlap an automatic scan.

These are opportunistic background refresh requests, not alarms. iOS determines
whether and when a grant occurs. Background App Refresh, power conditions and
app usage affect availability. Requests may use cellular data. They query saved
library titles through ready, authenticated source registrations, including
sources hidden by the Browse selection. They do not enable extensions, change
trust, fetch extension repository catalogs, download chapter images or request
notification permission. New-chapter system notifications remain a separate TODO.

## Scheduling and storage

`KamiAppDelegate` owns the shared AppModel and registers exactly one
`app.kami.reader.library-refresh` handler before launch finishes. The generated
Info.plist declares that identifier and the `fetch` background mode. Every scene
uses the same model. Local installed-source restoration is awaited before an
automatic check; repository-index refresh begins only when a scene is active.

`LibraryRefreshSettingsStore` stores a versioned JSON document of at most 4 KiB
in Application Support. It contains only enablement, a closed interval, next
eligibility and a finite last-attempt record. The bounded lexical validator
rejects duplicate/escaped keys, unsupported fields/versions and invalid dates.
Writes are atomic and read back before publication. Revisions and observed
bytes reject stale editors/external changes. Unreadable, corrupt or unconfirmed
storage closes scheduling in the current process until settings are reviewed
and saved; this is separate from the ability to load the library database.

Eligibility is persisted, so reopening or frequent scene changes do not postpone
the request. Beginning an attempt saves its ID and the next interval before
source work and submits the next system request. A busy library operation retries
no earlier than 15 minutes later; failures/cancellation otherwise retain the
chosen interval. Clock rollback clamps future eligibility to at most one
interval; a forward jump permits one attempt, not a burst of catch-up work.
An interrupted attempt retains its already-written future eligibility on reopen.
If the final outcome could not be stored, the panel does not claim completion.

Only Kami's request is cancelled/replaced. System unavailability and submission
errors are visible, and foreground return/settings changes retry reconciliation.
No timer polls or wakes the app at an exact interval.

## Cancellation, exclusion and fairness

The OS expiration callback is installed before work. `LibraryRefreshTaskOwner`
latches expiration even before a worker is attached, forwards cancellation and
reports completion once after the owned task drains. A late successful return
after expiration is unsuccessful from the OS's perspective. Saved database
commits are not rolled back or described as lost.

`LibraryUpdateService.run` adds an owned stream consumer with request-specific
cancellation. Cancelling its observer latches a request and invalidates only
that scan; it does not cancel/drop the consumer before the providers finish.
Cancellation during snapshot creation prevents source dispatch. A stale
observer cannot cancel the next scan. Existing atomic per-manga transactions,
configuration revalidation, exact URLs, library membership/revision and epoch
checks remain in force.

AppModel reserves the existing shared library operation lifetime. Manual and
automatic checks share the same owned worker; disabling automatic updates does
not cancel an unrelated manual check. Restore/migration stays excluded through
pending source requests and the saved-result reload, even after cancellation.
Cancellation cannot skip that reload, and a completed scan is not relabeled as
a rollback by a late observer cancellation.

Schema 8 adds `manga.last_library_update_attempt`, a local scan sequence. Claiming
a current target immediately before dispatch persists its attempt even when the
source hangs, fails, or the process is later interrupted. Subsequent snapshots
sort oldest attempts first, with a stable manga-ID tie break. Source queues follow
their oldest target instead of sorting source IDs; concurrency remains at most
three sources and one manga per source. Queued, unattempted titles therefore gain
priority at the next grant. This column is operational metadata, not reading
state, a backup format change or evidence of a successful chapter baseline.

## Evidence and remaining verification

See [this increment's verification](VERIFICATION-2026-10-06-AUTOMATIC-UPDATES.md)
and its implementation PR for actual commands, counts and exact-head Apple CI.
Offline fixtures exercise cancellation before start, during snapshot capture,
after a partial real SQLite commit and while a noncooperative provider is held.
They also cover storage failures/reopen, clock changes, system request failure,
overlapping launches, preference changes during drainage, schema upgrade and
cross-run rotation. Those tests do not establish iOS scheduling frequency,
battery use, physical-device termination/reboot behavior or settings interaction.

On an Apple device, verify default-off/no requests, enable/save and visible
system pending requests, background launch after cold startup, expiry with partial
results, switching Background App Refresh/Low Power Mode, disable during a run,
manual/automatic overlap and multiple windows. Confirm downloads stay paused
without an active scene, then inspect reopened Updates and the last-attempt
status after termination. Test a large library across several short grants.

Primary platform contracts: [Apple background-task setup and lifecycle](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app),
[registration](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)),
[earliest eligible time](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate),
[expiration](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler)
and [request replacement](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:)).
