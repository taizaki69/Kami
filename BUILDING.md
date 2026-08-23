# Building Kami

## What was verified, and where

| Component | Verified how |
|---|---|
| MihonCompatKit (parsers, VM, repo client, backup reader) | `swift test` on Windows/Swift 6.3.3 — **171/171 tests pass**, including 6 APK-signature regressions, 17 real-APK paths, 3 pinned adapter/tamper/concurrency paths, 7 bounded HTML/selector regressions, 46 pre-execution-verifier tests, and async HTTP/DEX coverage; exact-head macOS [Swift CI 32665870013](https://github.com/taizaki69/Kami/actions/runs/32665870013) passes |
| compat-audit CLI | built and run on Windows against 3 SHA-256-locked extension APKs; uploaded by Swift CI on macOS |
| KamiCore (models, SQLite store, source registry) | 2 portable Windows tests pass; exact-head macOS Swift CI passes all 8 tests, including SQLite migration, repository/user trust, wrong signer, verified rotation, downgrade and same-version replacement rejection, and downloaded registry admission |
| App UI + xcodeproj | generated with xcodegen and compiled with Xcode 16.4 for generic iOS Simulator and unsigned generic iOS device |
| IPA packaging | the `IPA Package` workflow builds a real Release `Kami.app`, packages `Kami-unsigned.ipa`, and uploads `Kami-unsigned-ipa` |

## macOS (full build)

```bash
brew install xcodegen             # once
bash scripts/bootstrap.sh         # generates Kami.xcodeproj
open Kami.xcodeproj               # or: bash scripts/build.sh simulator
bash scripts/test.sh              # SwiftPM tests + app tests
bash scripts/package_ipa.sh       # dist/Kami.ipa
```

App deployment target: iOS 17.0 (iPhone + iPad). The Swift packages retain an
iOS 16.0 minimum.

## Linux / Windows (compat kit only)

Requirements: Swift 5.9+ toolchain; on Windows also VS Build Tools C++ +
Windows SDK (for linking tests), and note `swift` driver output can be empty
when run from some shells — use the provided helper.

```bash
swift test --package-path Packages/MihonCompatKit        # bash
scripts\windows_dev_test.bat Packages\MihonCompatKit test # Windows cmd
scripts\windows_dev_test.bat Packages\MihonCompatKit release # optimized CLI/library build
swift run --package-path Packages/MihonCompatKit compat-audit inspect some-extension.apk
```

## Test corpus (real extensions)

```bash
bash scripts/fetch_corpus.sh
```

The three real Keiyoushi APKs are gitignored third-party binaries downloaded
from immutable release assets. Six tiny AOSP apksig conformance APKs are
vendored at a pinned source revision with the upstream Apache-2.0 license so CI
does not depend on Gitiles availability. The script verifies every SHA-256 in
`Tests/corpus/manifest.json` and restores missing fixtures; Swift CI runs it
before the tests.

## GitHub Actions

- `Swift CI`: corpus fetch, MihonCompatKit tests, release CLI build, KamiCore tests.
- `iOS Build`: generic Simulator plus unsigned generic-device compilation.
- `IPA Package`: unsigned device build and downloadable IPA artifact.

The repository became public on 2026-08-23, so its standard GitHub-hosted
runners now dispatch without consuming private-repository minutes. Exact-head
commit `a902d06` passes [Swift CI 32665870013](https://github.com/taizaki69/Kami/actions/runs/32665870013),
[iOS Build 32665869921](https://github.com/taizaki69/Kami/actions/runs/32665869921),
and [IPA Package 32665869959](https://github.com/taizaki69/Kami/actions/runs/32665869959).
The Swift job verifies the locked corpus, runs all 171 MihonCompatKit and 8
KamiCore tests, builds the optimized `compat-audit` CLI, and uploads the CLI.

A signed install still requires credentials owned by the user; no certificate,
profile, password, or Apple account secret belongs in this repository.
