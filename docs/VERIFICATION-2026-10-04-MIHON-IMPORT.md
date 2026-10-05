# Mihon import verification — 2026-10-04

Branch: `assistant/mihon-library-import-20261004`.
Base: `cca543fcbc6bedc87d04ed5f2d57af85096cc697` from
[PR #22](https://github.com/taizaki69/Kami/pull/22), ready and unmerged.
That base passed Linux 371 Compat + 351 Core/SQLite, macOS 371 Compat + 354 Core,
simulator/device builds and unsigned IPA. Its CI merge tree matched its head.
This increment adds the [measured Mihon import flow](MIHON_IMPORT.md).

## Local checks

Swift 6.3.3 on Linux through `scripts/linux-dev`:

- Core with the explicit SQLite module: **368 tests, 0 failures**.
- Portable Core: **126 tests, 0 failures**.
- MihonCompatKit: **372 tests, 0 failures**, including the pinned corpus baseline.
- App Swift frontend syntax parsing and `git diff --check` pass.
- Kotlin reproduction and independent Python wire/hash verification pass for
  all **six** fixture pairs; the previous five retain their exact locked bytes.

Seventeen new Core tests cover raw/gzip reference data; exact English source ID
and UUID grammar; rejection of other languages, aliases, repairs and malformed
URLs; full-width progress/order/duration; per-field timestamp conversion;
favorite=false and historical date fallback; duplicate progress/history union;
ambiguous categories and reported omissions; chapter parent conflicts within
the file and against existing data; dangling/removed history and reuse of exact
stored chapters; opaque unsupported fields; input/domain limits and cancellation.

The SQLite cases run Files acquisition, preview acknowledgement and the owned
commit operation, preserving the original input digest after provider-file
replacement. They exercise existing native collisions, repeated import,
foreign/stale preview rejection, late transactional rollback and native refresh
hiding an alternate edition without losing its state or discovery knowledge.
A fake transport checks all three native request paths only after explicit
source calls; decode/mapping itself issues none. No source is installed or
configured by this path.

One new Compat test compares the sixth reference fixture to its independent
Kotlin-decoded expectations and verifies provenance/hash locks. It is synthetic
serializer data, not an Android export or a claim about chapter existence.

## Publication and limits

Logs, input/evidence hashes, the root review and exact-head publication records
are retained under `.git/checkpoints/20261004-mihon-library-import/`. The PR
records Linux/macOS workflow jobs, merge-tree equality, simulator/device builds
and IPA artifact digest after CI finishes. Syntax parsing alone does not prove
Apple compilation.

The accepted subset is English MangaDex and the exact persisted paths described
in the mapping contract. Exclusions require explicit review; unsupported data is
not saved in an inert database, so users must keep the original file. No live
manga-site requests, arbitrary APK execution, personal backups, physical Files
provider/multiwindow interaction or large-library device benchmarks were used.
The broad compatibility and daily-reader objective remains active.
