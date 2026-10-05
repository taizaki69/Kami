# Project status — 2026-10-04

This is a dated snapshot, reviewed in America/Lima. `main` was
[`a479806ba81c71845ba0a154a096bf47736b7393`](https://github.com/taizaki69/Kami/commit/a479806ba81c71845ba0a154a096bf47736b7393).
The PRs below were open, ready for review and **unmerged** when checked.
Recheck GitHub before integrating; this page is not a live status feed.

## Main and the continuation stack

Main provides the reader/browse foundation, native MangaDex, persisted APK
admission and ten exact interpreted profiles. Its database is schema v2.
The [README](../README.md), [matrix](EXTENSION_COMPATIBILITY_MATRIX.md) and
[database guide](DATABASE.md) describe that snapshot.

PR #10 targets `main`; each subsequent PR targets the preceding feature branch.
Review and integrate in dependency order. The feature stack culminates in
PR #20, whose tested tree contains the earlier changes. Do not infer that an
open PR's features are already present in `main`.

| PR | Implemented scope | Reviewed head |
| --- | --- | --- |
| [#10](https://github.com/taizaki69/Kami/pull/10) | Category management, exact FoolSlide Customizable profile, corpus-role reconciliation and Linux test support | `ecc97bc20adbb57dd62c4d1618319306a3f02c08` |
| [#11](https://github.com/taizaki69/Kami/pull/11) | Persistent FoolSlide settings and obsolete-session revocation | `0ae9c4ded6e5dd01f577798122789827ec2e3842` |
| [#12](https://github.com/taizaki69/Kami/pull/12) | Manual library updates, durable discovery state and History resume | `36e038af443e36cd85dc2dd0c682c34fc2ec93d2` |
| [#13](https://github.com/taizaki69/Kami/pull/13) | Persistent downloads, pause/resume and offline reading | `c794982271b95b4c6d91e73917b5392363e481ce` |
| [#14](https://github.com/taizaki69/Kami/pull/14) | Bounded Mihon gzip/raw backup decoding with Kotlin reference fixtures and coverage reports | `8b7d98046dd04cd1ba99d2e27ee856629876f64e` |
| [#15](https://github.com/taizaki69/Kami/pull/15) | Native library backup codec, consistent bounded snapshot and Files export | `7bcbe7cb94c80527dd371a746fe591308f91aa49` |
| [#16](https://github.com/taizaki69/Kami/pull/16) | Atomic reading progress/history and navigation/dismissal save ordering | `b122ee94870b7b457739b5226b73de2943d24b1c` |
| [#17](https://github.com/taizaki69/Kami/pull/17) | Durable FoolSlide deployment/content identity across settings loss | `b15344da383a33b6a2d56d83fe2ed0f46d4a0877` |
| [#18](https://github.com/taizaki69/Kami/pull/18) | Exact chapter URL identity during refresh and updates | `1c6b43e2a199171766358e51ab9d8e2c5c93a22f` |
| [#19](https://github.com/taizaki69/Kami/pull/19) | Reject mutations from expired library snapshots | `32482b1ff5e41a6fa758a1bd550c38171dfbf8c3` |
| [#20](https://github.com/taizaki69/Kami/pull/20) | Shared operation coordination, reader lifetimes and generation-aware presentation across scenes | `a3c3560489040dd33b4a8412397232b66b48f6ea` |

The continuation reaches schema v7. Its
[operation contract](https://github.com/taizaki69/Kami/blob/a3c3560489040dd33b4a8412397232b66b48f6ea/docs/LIBRARY_OPERATIONS.md)
and [native backup contract](https://github.com/taizaki69/Kami/blob/a3c3560489040dd33b4a8412397232b66b48f6ea/docs/NATIVE_BACKUPS.md)
are pinned to the reviewed head. Native restore is still disabled: export,
decoder support and exclusive-operation infrastructure do not constitute a
restore flow. See [TODO.md](../TODO.md) for remaining acceptance criteria.

## Verified continuation checkpoint

PR #20 head: `a3c3560489040dd33b4a8412397232b66b48f6ea`.
CI checkout: `e45141d12341dcf68b876ceacaf471b08597f702`.
Both have tree `fbd4005691d399e643a99901f3966307d88f7d28`.

| Evidence | Result |
| --- | --- |
| [Swift CI 37245346593](https://github.com/taizaki69/Kami/actions/runs/37245346593) | Passed: 371 MihonCompatKit tests on each host; 330 KamiCore tests on macOS and 327 with SQLite on Linux; release CLI built/uploaded |
| [iOS Build 37245346585](https://github.com/taizaki69/Kami/actions/runs/37245346585) | Passed: simulator and unsigned generic-device compilation |
| [IPA Package 37245346596](https://github.com/taizaki69/Kami/actions/runs/37245346596) | Passed: unsigned device app packaged and uploaded as artifact `11318574371` |

The IPA artifact digest is
`sha256:04bbfdb833d4034dc28ce8d8c2edfd83b00274a9043461abc2839b87ddcde036`;
its recorded expiry is 2027-01-02 23:52:57 UTC. Artifacts can expire or be
removed. Compilation and deterministic tests do not establish physical-device
interaction, live-site availability or interactive multiwindow behavior.
These runs validate PR #20's tree, not the reviewed `main` tree.

## Documentation audit

The 17 tracked Markdown files on the reviewed `main` were checked for scope,
stale status, build instructions and pending work. Corrections include:

- Ten exact profiles in code, including EternalMangas and DocTruyen3Q. The
  manifest still labels their fixtures `measurement`; profile admission and
  role labels are different facts. PR #10 reconciles the roles.
- The checked-in main measurement baseline reports **387** unique unregistered
  external methods, not 432. The eleven-file role still includes those two
  profiles. The continuation has a different measurement set and baseline.
- Backup interoperability uses the verified gzip/raw protobuf contract;
  the old zstd/zlib and completed-schema claims were incorrect.
- Package test commands now include KamiCore explicitly, and old Windows/macOS
  test totals are labelled historical. Main's CI runs on macOS; continuation
  Linux coverage is documented separately.
- Reader retry already refreshes the source request on main. Networking docs
  no longer describe it as reusing a stale request.
- Historical handoff evidence is retained below a current entry point. Existing
  licensing and corpus attribution notices remain unchanged.

Maintain this page when PRs merge or the verified head changes. Keep feature
details in their topic documents and actionable remaining work in the tracker.
