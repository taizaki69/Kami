# Kami

A native iOS manga reader built around **real Mihon/Tachiyomi extension
ecosystem compatibility** — not a lookalike. Kami treats the ability to work
with actual, current extension APKs and extension stores as its core
engineering problem. See `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md` for the
verified ecosystem research and `docs/EXTENSION_COMPATIBILITY_MATRIX.md` for
measured status.

**Honest status (2026-08-21):** the extension pipeline — store index (both
formats), APK download, ZIP/DEFLATE, binary manifest, DEX parsing, and the
compatibility analyzer — is implemented in pure Swift and verified against
live extensions. **Executing extension source code (the DEX runtime) is the
next major track** (`docs/EXTENSION_RUNTIME.md`). Until it lands, Kami reads
through native sources (MangaDex built in).

## Layout

```
App/                    SwiftUI app (iOS 16+)
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
./scripts/bootstrap.sh        # xcodegen + project + optional corpus
./scripts/build.sh            # simulator build
./scripts/test.sh             # package tests + app tests
./scripts/package_ipa.sh      # dist/Kami.ipa (unsigned; sign at install)
```

Requirements: Xcode 15+, xcodegen. Details: `BUILDING.md`, `docs/IPA_BUILD.md`.

## Verified on Windows too

The pure-Swift compatibility kit builds and its tests run on Windows with the
Swift 6.3 toolchain (`scripts/windows_dev_test.bat`); the analyzer CLI
(`compat-audit`) was used to produce every measurement in the compatibility
matrix from real APKs on a Windows host.

## Non-goals / legality

Kami bundles no content and no sources' code. Extensions are user-installed
from third-party repositories at the user's direction. Licensing notes:
`LICENSES.md`.
