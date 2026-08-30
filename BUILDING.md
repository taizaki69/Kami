# Building Kami

## What was verified, and where

| Component | Verified how |
|---|---|
| MihonCompatKit (parsers, VM, repo client, backup reader) | Current local `swift test` on Windows/Swift 6.3.3 passes **214/214**; the suite includes corpus-lock and APK-signature regressions, real-APK constructor/source-path coverage across six execution fixtures, deterministic structural-plan and privacy-safe diagnostics regressions, seven bounded OkHttp interceptor-chain regressions, adapter/admission tests, and the end-to-end Baozi profile |
| compat-audit CLI | optimized build plus deterministic directory-level `plan` and `gaps` behavior verified on Windows; the locked corpus reports current candidates, legacy blockers, ranked unregistered external invocations, and unsupported opcodes, continues past malformed files, omits local paths/filenames/request secrets, and returns failure after all artifacts; exact-head Swift CI uploaded the optimized CLI |
| KamiCore (models, SQLite store, install/admission/factory, source registry, reader image pipeline) | Current portable Windows `swift test` passes **14/14**, including exact Baozi factory admission; the pre-Baozi exact-head macOS Swift CI passed all 23 tests covering bounded reader settings/prefetch, exact image headers, in-flight deduplication/cache, response rejection, Browse routing, SQLite migration, extension installation/restoration/factory, and registry lifecycle coverage |
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

The lock contains 27 APK artifacts: six real Keiyoushi execution fixtures (two
legacy lib 1.4 and four current lib 1.6), 15 current lib 1.6 Keiyoushi
measurement-only fixtures under `Tests/corpus/measurement/`, and six tiny AOSP
apksig conformance fixtures. Thus 19 locked artifacts are current lib 1.6
(four execution plus 15 measurement). The measurement set is
behavior-stratified, not statistical. The earlier 16-artifact measurement run
occupied 1.24 MB (1,242,086 bytes) before Baozi moved into the execution role.

The remaining 15 measurement APKs are parsed, signature-verified for parser
conformance, and statically audited only. The pre-promotion deterministic run
analyzed 16/16 with zero errors, found 12 structural candidates and four
stable-wrapper blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC), and
reported 626 unique unregistered external method surfaces with zero unsupported
opcodes. That aggregate is historical to the former 16-artifact measurement
role, not a compatibility rate. Membership never grants signer trust, admission,
installation, execution, or compatibility proof. Run the non-executing audit
with `compat-audit gaps Tests/corpus/measurement`.

The current locked measurement baseline is 15/15 analyzed artifacts, 11
structural candidates, 540 unique unregistered external method surfaces, and
zero unsupported opcodes. These are static prioritization results, not a
compatibility percentage or runtime proof.

With the corpus present, the current local Windows/Swift 6.3.3
`MihonCompatKit` suite passes 214/214 tests, including the Baozi real-APK
regressions. The exact-head GitHub workflows listed below still refer to the
previous pre-promotion checkpoint; new workflow results belong to the integrated
Baozi milestone.

All 21 real Keiyoushi APKs are vendored, SHA-256-pinned Apache-2.0 test inputs;
they are not linked into or shipped by the iOS app. Their attribution is in
`Tests/corpus/KEIYOUSHI-EXTENSIONS-NOTICE.md`. The AOSP fixtures are likewise
vendored at a pinned source revision with the upstream Apache-2.0 license. This
keeps CI independent of Keiyoushi release rotation and Gitiles availability.
The signer regression explicitly authenticates all six real Keiyoushi execution
APKs (Akuma, MangaDex, BatCave, Kawii Manga, MangaMelon, and Baozi Manhua);
the six AOSP files are separate conformance fixtures.
The script verifies every SHA-256 in `Tests/corpus/manifest.json` and only uses
the recorded upstream URL as a best-effort fallback for a missing or
hash-mismatched file.

The Baozi Manhua execution fixture is `Tests/corpus/baozimanhua.apk`. The
profile is admitted only when its exact SHA-256
`7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`, signer
fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, manifest
identity, and declared source ID `5724751873601868259` match. Its deterministic
regression uses fake transport to prove popular, latest, text search, combined
details/chapters, pages, the static header-plus-four-`Select` filter schema,
and the bounded preference surface. It applies a valid non-default tag filter
state and proves a distinct filtered request, in addition to rejecting mutated
filter schemas. It also proves the DEX image-request host rewrite without
contacting a manga site.

For downloaded execution, the factory preflights the exact profile source-ID set
before DEX construction and postvalidates the IDs returned by the constructed
source. `SourceRegistry` removes downloaded IDs only when their recorded package
owner matches the disabling package. The exact raw-byte profile constructors are
a deliberate built-in/test seam: they still reverify exact hash and signer, but
the downloaded app path requires persisted admission and the sole factory.

The compatibility host bounds source-model outputs before they cross the
app-facing seam: manga-page and page-list collections are capped at 2,048
entries, manga updates at 20,000 chapters, and `Page` URL/image-URL fields at
8 KiB. `ReaderView` retries chapter loading via `.task(id: reloadID)` and its
dismissal cleanup invalidates the load generation. Reader-image retry request
regeneration/expiry remains deferred. Reader image fetching inherits the
source's admitted transport policy, defaults to HTTPS-only, validates the
initial URL/headers before any injected or production transport call, and
allows HTTP only through explicit source opt-in; redirect policy remains
source-scoped.

`ReaderView` resolves each page's source `ImageRequest` asynchronously and
passes its URL and headers to the image pipeline. The app does not yet expose or
persist the Baozi preference values. The current await and reader paths do not
execute source OkHttp interceptors or retain DEX `Request` tags, so banner
cropping, redirect-domain rewriting, and missing-image behavior remain
unproven through reader loads.

## GitHub Actions

- `Swift CI`: corpus fetch, MihonCompatKit tests, release CLI build, KamiCore tests.
- `iOS Build`: generic Simulator plus unsigned generic-device compilation.
- `IPA Package`: unsigned device build and downloadable IPA artifact.

The repository became public on 2026-08-23, so its standard GitHub-hosted
runners now dispatch without consuming private-repository minutes. The previous
exact corpus head `a376064` passes
[Swift CI 33279595763](https://github.com/taizaki69/Kami/actions/runs/33279595763),
[iOS Build 33279595816](https://github.com/taizaki69/Kami/actions/runs/33279595816),
and [IPA Package 33279595746](https://github.com/taizaki69/Kami/actions/runs/33279595746).
The Swift job found all 27 corpus fixtures already hash-matched, ran 192
MihonCompatKit and 23 KamiCore tests, built the optimized `compat-audit` CLI,
and uploaded it. The iOS workflow passed simulator and unsigned-device builds;
the IPA workflow built, packaged, and uploaded the unsigned IPA.

A signed install still requires credentials owned by the user; no certificate,
profile, password, or Apple account secret belongs in this repository.
