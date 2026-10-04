# Shared library operations verification — 2026-10-04

Branch: `assistant/shared-library-operations-20261004`.
Base: `32482b1ff5e41a6fa758a1bd550c38171dfbf8c3` from
[PR #19](https://github.com/taizaki69/Kami/pull/19), ready and unmerged.
The base passed Linux 371 Compat + 310 Core/SQLite, macOS 371 Compat + 313 Core,
simulator/device compilation and unsigned IPA; its CI merge tree matched the
published head tree. Base evidence is retained under
`.git/checkpoints/20261004-library-mutation-contexts/`.

## Local checks

Swift 6.3.3 on Linux via scripts/linux-dev:

- KamiCore with the explicit SQLite module: **327 tests, 0 failures**.
- Portable KamiCore without that module: **112 tests, 0 failures**.
- MihonCompatKit: **371 tests, 0 failures**, including the pinned corpus baseline.
- App/Sources Swift frontend syntax parse and git diff --check pass.

Fifteen new deterministic coordinator tests use MainActor continuation gates,
not sleeps. They cover synchronous admission, cancellation before start and
while suspended, observer cancellation, throwing work, independently owned
children, two scenes and idempotent close, foreign/consumed tokens, exclusive
abort/commit publication, cancellation after publication, stale lifecycle
closures, pending-prompt ownership, global/worker limits and private scope checks.
Two SQLite writer tests prove ownership through cancelled-observer drainage and
retained retry after rejection during an aborted exclusive operation. Existing
atomic reading/context/source/download suites also pass in the full run.

The App integration review follows every Task, lifecycle callback and direct
Store access. It includes startup/recovery, download and scan stream drainage,
pending signer trust, detached source construction, old ID-only actions and
reader cleanup after chapter navigation. See the
[operation contract and producer inventory](LIBRARY_OPERATIONS.md).

## Evidence and limits

Logs, a hash manifest, root review and publication evidence are stored locally
under `.git/checkpoints/20261004-shared-library-operations/`. The implementation
PR records exact published head, merge-tree equality, Apple workflow jobs and
artifact digests once CI completes. Local syntax parsing is not SwiftUI
compilation. Package tests and Apple builds do not establish physical-device
or interactive multiwindow behavior.

Restore stays disabled. Preview, transactional merge, durable dependency checks
and epoch rotation remain separate required work. No APK/runtime profile,
permission, signature or network admission was widened by this change.
