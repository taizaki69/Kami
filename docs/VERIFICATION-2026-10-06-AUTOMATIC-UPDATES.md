# Automatic updates verification — 2026-10-06

Base: `3888625ef213dbd7e5cfb389a5cbb4687c783ae5` ([PR #31](https://github.com/taizaki69/Kami/pull/31)),
ready/open/unmerged with five matching-tree checks and three verified artifacts.
The implementation branch is `assistant/background-library-updates-20261006`.
Final head, CI jobs, artifact IDs/digests and completion state belong to the PR
and `.git/checkpoints/20261006-background-library-updates/` publication evidence.

## Regression scope

- `LibraryRefreshTests`: default-off and persisted eligibility, non-postponing
  lifecycle reconciliation, system unavailability, submit failure/retry, due/early
  checks, partial outcome, concurrent-launch exclusion, disable/system restriction
  during drainage, observer expiry, interval changes, clock jumps, corrupt/stale/
  external ABA documents, uncertain writes, final-outcome write failure, file
  reopen, strict input bounds and OS completion before/after expiration.
- `LibraryUpdateServiceTests`: request cancellation during begin, noncooperative
  provider drainage with a retained partial result, precancelled admission,
  source queue priority and a real SQLite scan holding a shared operation lease
  against exclusive restore until a late provider drains.
- `LibraryUpdatePersistenceTests`: interrupted attempts survive reopen and rotate
  later manga first; removed/re-added or terminal targets cannot claim work;
  schema 7→8 preserves chapter identity, read/bookmark/offset and history.

The full portable Core, SQLite Core and Compat suites are required, plus app/
hosted-source parsing, whitespace and changed Markdown links. Apple CI must
verify simulator/device compilation, hosted reader tests and unsigned IPA at
the exact published head/tree before the PR becomes ready. Package/hosted tests
use offline fixtures; they do not run live manga sources or arbitrary APKs.

## Limits

Local final suites passed: **224 portable Core**, **490 Core with SQLite**, and
**379 Compat**, including **22 new regressions** (14 scheduling/ownership,
5 scanner coordination and 3 persistence/migration). App and hosted-test Swift
sources parse on Linux. Apple type checking, linking and execution remain
separate gates recorded against the published head on the PR.

The hosted renderer suite still tests rendering, not background OS grants or
this settings panel. Physical background launch, restrictions, suspension/
termination/reboot, cellular/power behavior and multiwindow interaction remain
unverified. iOS may delay or skip a scheduled request. Notification permission
and new-chapter notifications are not implemented in this increment. The broad
reader and compatibility goal remains active; no PR is merged by this workflow.
