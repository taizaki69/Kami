# Building Kami

## What was verified, and where

| Component | Verified how |
|---|---|
| MihonCompatKit (parsers, VM, repo client, backup reader) | Local `swift test` on Windows/Swift 6.3.3 — **192/192 tests pass**, including the three corpus-lock regressions, 6 APK-signature regressions, 21 real-APK source/execution paths, 3 deterministic structural-plan regressions, 4 privacy-safe compatibility-diagnostics regressions, 3 BatCave adapter/tamper/concurrency paths, and end-to-end Kawii/MangaMelon profiles |
| compat-audit CLI | optimized build plus deterministic directory-level `plan` and `gaps` behavior verified on Windows; the locked corpus reports current candidates, legacy blockers, ranked unregistered external invocations, and unsupported opcodes, continues past malformed files, omits local paths/filenames/request secrets, and returns failure after all artifacts; the optimized CLI was uploaded by the historical exact-head Swift CI run |
| KamiCore (models, SQLite store, install/admission/factory, source registry, reader image pipeline) | 12 portable Windows tests pass; the historical exact-head macOS Swift CI run passed all 23 tests, including bounded reader settings/prefetch, exact image headers, in-flight deduplication/cache, response rejection, Browse routing, SQLite migration, extension installation/restoration/factory, and registry lifecycle coverage |
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
swift run --package-path Packages/MihonCompatKit compat-audit plan some-extension.apk
swift run --package-path Packages/MihonCompatKit compat-audit gaps path/to/apks
```

## Test corpus (real extensions)

```bash
bash scripts/fetch_corpus.sh
```

The lock contains 27 APK artifacts: five real Keiyoushi execution fixtures (two
legacy lib 1.4 and three current lib 1.6), 16 current lib 1.6 Keiyoushi
measurement-only fixtures under `Tests/corpus/measurement/`, and six tiny AOSP
apksig conformance fixtures. Thus 19 locked artifacts are current lib 1.6
(three execution plus 16 measurement). The measurement set is
behavior-stratified, not statistical, and is 1.24 MB (1,242,086 bytes).

The 16 measurement APKs are parsed, signature-verified for parser conformance,
and statically audited only. A deterministic run analyzed 16/16 with zero
errors, found 12 structural candidates and four stable-wrapper blockers
(Komga, MangaPlus, NHentai.xxx, and XCOMIC), and reported 626 unique
unregistered external method surfaces with zero unsupported opcodes. Membership
never grants signer trust, admission, installation, or execution. Run the
non-executing audit with `compat-audit gaps Tests/corpus/measurement`.

All 21 real Keiyoushi APKs are vendored, SHA-256-pinned Apache-2.0 test inputs;
they are not linked into or shipped by the iOS app. Their attribution is in
`Tests/corpus/KEIYOUSHI-EXTENSIONS-NOTICE.md`. The AOSP fixtures are likewise
vendored at a pinned source revision with the upstream Apache-2.0 license. This
keeps CI independent of Keiyoushi release rotation and Gitiles availability.
The script verifies every SHA-256 in `Tests/corpus/manifest.json` and only uses
the recorded upstream URL as a convenience fallback for a missing or
hash-mismatched file.

## GitHub Actions

- `Swift CI`: corpus fetch, MihonCompatKit tests, release CLI build, KamiCore tests.
- `iOS Build`: generic Simulator plus unsigned generic-device compilation.
- `IPA Package`: unsigned device build and downloadable IPA artifact.

The repository became public on 2026-08-23, so its standard GitHub-hosted
runners now dispatch without consuming private-repository minutes. The last
exact-head CI evidence is historical: compatibility-diagnostics implementation
commit `e56bd9a` passes [Swift CI 32683073872](https://github.com/taizaki69/Kami/actions/runs/32683073872),
[iOS Build 32683073885](https://github.com/taizaki69/Kami/actions/runs/32683073885),
and [IPA Package 32683073873](https://github.com/taizaki69/Kami/actions/runs/32683073873).
Those runs predate the current corpus expansion and 192-test checkout; they
remain the available CI evidence until a new commit is pushed and rerun. The
historical Swift job verified its then-locked corpus, ran 189 MihonCompatKit
and 23 KamiCore tests, built the optimized `compat-audit` CLI, and uploaded the
CLI.
The iOS build log has no warnings, including the prior iPad multitasking
orientation warning.

A signed install still requires credentials owned by the user; no certificate,
profile, password, or Apple account secret belongs in this repository.
