# Kami — Task Tracker

Reviewed **2026-10-04** against `main` at `a479806` and the open continuation
stack through PR #23. Exact heads and CI evidence are in
[project status](docs/PROJECT_STATUS.md).

Legend: `[x]` implemented in reviewed main; `[~]` implemented in an open PR,
pending integration; `[ ]` remaining work. Partial foundations are described
in prose so that a checked box does not imply general compatibility.

## P0 — Integrate the verified continuation

These changes exist and should not be reimplemented from the older main
tracker. Follow the dependency order in the status page; PR #21 is a separate
documentation change against main. Verify the final integrated tree.

- [~] Category management and exact FoolSlide Customizable support — [#10](https://github.com/taizaki69/Kami/pull/10).
- [~] Persistent FoolSlide settings and source-session revocation — [#11](https://github.com/taizaki69/Kami/pull/11).
- [~] Manual library updates, durable discovery state and History resume — [#12](https://github.com/taizaki69/Kami/pull/12).
- [~] Persistent download queue, pause/resume and offline reader — [#13](https://github.com/taizaki69/Kami/pull/13).
- [~] Correct bounded Mihon gzip/raw protobuf decoding and explicit coverage reports — [#14](https://github.com/taizaki69/Kami/pull/14).
- [~] Native backup snapshot, versioned codec and Files export — [#15](https://github.com/taizaki69/Kami/pull/15).
- [~] Atomic reading state and navigation/dismissal save ordering — [#16](https://github.com/taizaki69/Kami/pull/16).
- [~] Durable FoolSlide content binding — [#17](https://github.com/taizaki69/Kami/pull/17).
- [~] Exact chapter URL identity — [#18](https://github.com/taizaki69/Kami/pull/18).
- [~] Durable mutation contexts and shared operation coordination — [#19](https://github.com/taizaki69/Kami/pull/19), [#20](https://github.com/taizaki69/Kami/pull/20).
- [~] Reviewed native restore with atomic conservative merge — [#22](https://github.com/taizaki69/Kami/pull/22).
- [~] Reviewed Mihon import for English MangaDex and exact persisted URL forms — [#23](https://github.com/taizaki69/Kami/pull/23).

## P0 — Restoration guarantees and remaining validation

The native flow below is implemented and verified in PR #22; PR #23 adds the
measured Mihon adapter. Keep these guarantees when extending either path.
Builds and deterministic tests do not establish physical Files-provider use.

- [~] Native restore preview and review UI. Read one bounded immutable file;
  show new/existing records, unresolved sources, deployment conflicts and any
  explicit exclusions. Tie approval to the input bytes, target state and policy.
- [~] Transactional native merge. Revalidate the preview after obtaining the
  exclusive operation scope; reject stale previews and active conflicting work.
  Commit all library changes atomically, rotate the epoch only on success, and
  publish the new presentation generation after commit. Failure must preserve
  the original library and epoch.
- [~] Identity and state preservation. Match exact source plus UTF-8 URL bytes;
  preserve read/bookmark/progress/history monotonically, category membership,
  hidden chapters and discovery state. Do not create Updates from imported
  history or bind existing FoolSlide content to another deployment.
- [~] Restore regression coverage. Exercise rollback, cancellation, stale/foreign
  preview rejection, repeated import, Unicode-distinct URLs, source conflicts,
  limits and active reader/download/scanner lifetimes. Verify Files UI builds
  and record remaining interaction checks.
- [~] Mihon import for English MangaDex source ID `2499283573021220255` and
  exact `/manga/<UUID>` and `/chapter/<UUID>` forms. The adapter preserves
  per-field timestamp units and category-order references, reports exclusions
  and requires acknowledgement. Original backups must be retained.
- [ ] Expand source/language mapping and supported fields only with producer
  and native-operation evidence. Other MangaDex language IDs must not be routed
  through the English source. Never import APK installation or trust authority.
- [ ] Exercise Files providers, cancellation and multiple windows on Apple
  hardware; measure bounded memory use and responsiveness with large libraries.
- [ ] Keep fuzzy title/chapter matching in an explicitly selected source
  migration flow, separate from exact-identity restoration.

## P1 — Reader and daily use

- [ ] Review previous/next chapter behavior across online/offline transitions,
  interruption and resume against the continuation implementation. Extend it
  with configurable tap actions, fit/crop controls and brightness override.
- [ ] Add memory-pressure cache purging and bounded long-image tiling; profile
  500-page webtoon chapters, rotation and interrupted/retried loading.
- [ ] Add iPad dual-page spreads and cover-page separation.
- [ ] Add scheduled library scans and notification summaries on top of the
  implemented manual scanner, including cancellation and unavailable-source reports.
- [ ] Expand persistent preference UI beyond FoolSlide only for measured schemas;
  preserve typed validation, source revocation and content-identity constraints.
- [ ] Add global search over enabled sources with bounded concurrency and
  cancellation, then an explicit source-migration review flow.
- [ ] Add local CBZ/ZIP reading with bounded extraction and page ordering.
- [ ] Validate VoiceOver, large text and physical-device performance with a
  user-signed build. Unsigned CI artifacts do not establish device usability.

## P1 — Compatibility and diagnostics

Main has ten exact current profiles plus two legacy constructor fixtures.
The catalog and [matrix](docs/EXTENSION_COMPATIBILITY_MATRIX.md) define the
actual boundary; corpus membership and static counts never grant admission.

- [ ] Harden regex matching with a demonstrable work/time bound or a suitable
  bounded matcher. Existing pattern/input/output size limits do not bound
  worst-case `NSRegularExpression` execution.
- [ ] Expand interpreter opcodes, external hierarchy handling and differential
  conformance from reproducible fixtures — [issue #1](https://github.com/taizaki69/Kami/issues/1).
- [ ] Select the next unadmitted locked candidate from measured gaps; add exact
  source-operation, failure and bound regressions before catalog promotion.
- [ ] Extend dynamic filters, serialization/DOM helpers and non-GET interceptor
  behavior only where a measured source requires them.
- [ ] Add persistent cookie handling and a user-mediated WKWebView challenge
  flow with source isolation, bounded retries and cookie/User-Agent continuity.
- [ ] Add the Diagnostics screen and user-selected redacted export — [issue #4](https://github.com/taizaki69/Kami/issues/4).
  Typed gap capture and deterministic CLI promotion already exist; raw request
  values, credentials and arbitrary error strings must remain excluded.
- [ ] Implement bounded portable pixel/JPEG behavior before claiming Baozi
  banner transforms. Metadata-only bitmap shims do not prove image processing.

## P1 — Build helpers found during the documentation audit

- [ ] Correct `scripts/test.sh`: run both portable packages without requiring
  Xcode; do not claim app tests when no app test target is defined. Verify
  failure propagation and platform-specific coverage.
- [ ] Correct `scripts/package_ipa.sh`: make the output path absolute before
  changing into the temporary build directory, handle the unsigned suffix
  without a failing command substitution under `set -e`, and remove the obsolete
  `PackageApplication` fallback. Test packaging/failure paths and validate on
  Apple CI. The independent IPA workflow is the documented route meanwhile.

## Foundations implemented in reviewed main

- [x] Bounded APK ZIP/DEFLATE, binary manifest and DEX parsing; signer verification.
- [x] Repository indexes, content-addressed install, persisted trust and exact
  admitted-profile construction with package-owned registry lifecycle.
- [x] Ten exact current source profiles, native MangaDex and generic Browse filters.
- [x] SQLite schema v2 and library/chapter state; historical tests remain in the matrix.
- [x] LTR/RTL/webtoon reader, settings, zoom/pan, header-aware bounded image
  pipeline, prefetch and source-request regeneration on explicit Retry.
- [x] Swift package, simulator, unsigned-device and IPA workflows.

The interpreter/host/API bridge remains partial. The early backup reader in
main is not proof of Mihon interoperability; use the corrected decoder PR and
[backup guide](docs/BACKUP_COMPATIBILITY.md). Historical completion evidence is
preserved in [HANDOFF.md](HANDOFF.md), not duplicated as current test counts.
