# Native restore verification — 2026-10-04

Branch: `assistant/native-library-restore-20261004`.
Base: `a3c3560489040dd33b4a8412397232b66b48f6ea` from
[PR #20](https://github.com/taizaki69/Kami/pull/20), ready and unmerged.
That base passed Linux 371 Compat + 327 Core/SQLite, macOS 371 Compat + 330 Core,
simulator/device compilation and unsigned IPA. Its CI merge tree matched its
published head. This increment implements the complete native preview/commit/
review path described in [Native backups](NATIVE_BACKUPS.md).

## Local checks

Swift 6.3.3 on Linux via `scripts/linux-dev`:

- Core with the explicit SQLite module: **351 tests, 0 failures**.
- Portable Core without that module: **115 tests, 0 failures**.
- MihonCompatKit: **371 tests, 0 failures**, including the pinned corpus baseline.
- App/Sources Swift frontend syntax parsing and `git diff --check` pass.

Twenty-one new temporary-SQLite restore tests cover immutable preview, exact
UTF-8 manga/chapter identity and signed IDs; conservative metadata/currentness,
read/bookmark/progress/history/category/discovery merges; repeated import;
foreign and stale previews after domain/configuration/identity changes and
save/revert ABA; active durable owners; transactional rollback on late failure,
writer contention and epoch failure; pre-commit cancellation; source conflicts
and explicit exclusion; inert unresolved Foo provenance; combined-domain limits,
malformed storage and category-order overflow; retained downloads/receipts and
unchanged trust/settings; and file replacement after review.

Five of those tests run the actual `startLibraryRestore` coordinator operation
against SQLite. They cover idle readers and queued ordinary work, synchronous
exclusive reservation, failure without generation publication, cancellation
before scheduling, observer cancellation, and cancellation during publication
after a successful commit. No timing sleeps are required.

Three additional file-reader tests cover exact bytes at the inclusive limit,
oversize/directory/non-file inputs, cancellation, symlinks and nonblocking FIFO
rejection. Tests use local synthetic fixtures, not personal library exports.

## Publication evidence and limits

Logs, hashes, root review and publication records are checkpointed under
`.git/checkpoints/20261004-native-library-restore/`. The implementation PR records
the exact published head, CI merge-tree equality, Linux/macOS package results,
simulator/device build jobs and IPA digest after those workflows complete.
Local syntax parsing is not Apple compilation, and neither package tests nor
builds prove Files-provider interaction, physical multiwindow behavior or
large-library device memory/performance.

Schema remains version 7. Native restore neither broadens executable extension
admission nor imports settings/trust/downloads. Mihon decoding is still separate:
source/URL adaptation and unsupported-field review remain required before a
Mihon archive can enter the product restore path. No PR is merged automatically.
