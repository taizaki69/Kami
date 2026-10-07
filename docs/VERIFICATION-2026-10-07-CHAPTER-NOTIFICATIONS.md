# Chapter notifications — 2026-10-07

This continuation is based on PR #32 at
`e0bf2d7b4fefc0208dd3fb092536c4ba84602841`, which passed all five CI checks:
Linux 490 Core/SQLite + 379 Compat, macOS 502 Core + 379 Compat, both iOS builds,
two hosted renderer tests and unsigned IPA packaging. Its head/CI tree and all
three artifact upload digests were independently matched. That PR is ready,
open and unmerged.

The new increment adds [chapter notifications](CHAPTER_NOTIFICATIONS.md).
Seventeen new regressions cover permission separation, pre-prompt disable,
durable claim ordering, uncertain/dismissed recovery, duplicate suppression,
disable/re-enable during a held OS call, cancellation drainage, storage failures,
OS failure, unavailable durable storage, one-scene routing, schema 8 upgrade,
baseline/pre-enable exclusion, byte-distinct discoveries, partial recovery,
settings ABA, transaction rollback and a bounded scan pass.

Local full suites pass 234 portable Core, 507 Core/SQLite and 379 Compat tests.
App/hosted sources parse, whitespace checks pass and 82 relative Markdown
references resolve. The focused portable notification group passes 10 tests.
Exact-head Apple builds and artifacts are recorded in the implementation PR
when terminal. No device alert delivery,
permission dialog, notification tap, Focus, multiwindow or physical background
grant is claimed from package or hosted reader tests. The broad native reader
and compatibility objective remains active.

Durable checkpoint: `.git/checkpoints/20261007-chapter-notifications/`.
