# Kami

A native iOS manga reader built around **real Mihon/Tachiyomi extension
ecosystem compatibility** — not a lookalike. Kami treats the ability to work
with actual, current extension APKs and extension stores as its core
engineering problem. See `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md` for the
verified ecosystem research and `docs/EXTENSION_COMPATIBILITY_MATRIX.md` for
measured status.

**Honest status (2026-08-22):** the pure-Swift extension pipeline now covers
store indexes, APK download, bounded ZIP/DEFLATE and binary-manifest parsing,
validated DEX parsing, compatibility analysis, and an initial interpreter with
a bounded pre-execution geometry/control-flow, exception-table, register-bounds,
and exact primitive/constructor-state register dataflow verifier.
Pinned real-APK tests execute the Akuma, MangaDex, and BatCave entry
constructors plus BatCave's `getBaseUrl`, `getLang`, `getName`, and `getId`
methods. BatCave's real popular-manga path now runs through Kotlin class
initialization, filters, collections, iteration, coroutine setup, and a bounded
pure OkHttp model. It constructs and asserts the exact BatCave popular POST
request, creates an inert call, and stops at the unresolved `awaitSuccess`
transport seam without network I/O. This is a measured M1/M2 runtime slice,
**not end-to-end source compatibility**: no interpreted response has completed,
and details, chapters, pages, transport, and much of the Kotlin/Java surface
remain open (`docs/EXTENSION_RUNTIME.md`). Kami currently reads through its
native MangaDex source.

## Layout

```
App/                    SwiftUI app (iOS 17+)
Packages/
  MihonCompatKit/       Extension compatibility: APK/ZIP, AXML, DEX,
                        store index (index.pb/index.min.json), backup reader,
                        analyzer + compat-audit CLI
  KamiCore/             Domain models, SQLite store, native sources, services
scripts/                bootstrap / build / test / package_ipa / fetch_corpus
docs/                   analysis, matrix, runtime plan, per-area docs
```

## Quick start (macOS)

```bash
bash scripts/bootstrap.sh        # xcodegen + project + optional corpus
bash scripts/build.sh            # simulator build
bash scripts/test.sh             # package tests + app tests
bash scripts/package_ipa.sh      # dist/Kami.ipa (unsigned; sign at install)
```

Requirements: Xcode 15+, xcodegen. Details: `BUILDING.md`, `docs/IPA_BUILD.md`.

Moving development to another computer? Start with [HANDOFF.md](HANDOFF.md);
it records the known-good SHA, restore commands, verification evidence,
security boundaries, and the recommended next implementation sequence.

## Verified on Windows too

The compatibility kit and all 103 tests run on Windows with Swift 6.3
(`scripts/windows_dev_test.bat`). GitHub Actions independently runs the pinned
real-APK suite on macOS, compiles both Simulator and unsigned device targets,
and publishes an unsigned IPA artifact. The `compat-audit` CLI produced the
measured compatibility matrix from the locked corpus.

## Non-goals / legality

Kami bundles no content and no sources' code. Extensions are user-installed
from third-party repositories at the user's direction. Licensing notes:
`LICENSES.md`.
