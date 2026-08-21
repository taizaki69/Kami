# Building Kami

## What was verified, and where

| Component | Verified how |
|---|---|
| MihonCompatKit (all parsers, repo client, backup reader) | `swift test` on Windows, Swift 6.3.3 — **9/9 tests pass**; `swift build -c release` succeeds |
| compat-audit CLI | built + run on Windows against 3 real extension APKs and the live store index |
| KamiCore (models, MangaDex source) | `swiftc -typecheck` clean on Windows (DB files are `#if canImport(SQLite3)`, compiled on Apple/Linux) |
| App UI, xcodeproj, IPA packaging | **Not compiled yet** — requires macOS/Xcode; code and project spec are in place (`project.yml` → xcodegen) |

## macOS (full build)

```bash
brew install xcodegen          # once
./scripts/bootstrap.sh         # generates Kami.xcodeproj
open Kami.xcodeproj            # or: ./scripts/build.sh simulator
./scripts/test.sh              # SwiftPM tests + app tests
./scripts/package_ipa.sh       # dist/Kami.ipa
```

Deployment target: iOS 16.0 (iPhone + iPad).

## Linux / Windows (compat kit only)

Requirements: Swift 5.9+ toolchain; on Windows also VS Build Tools C++ +
Windows SDK (for linking tests), and note `swift` driver output can be empty
when run from some shells — use the provided helper.

```bash
swift test --package-path Packages/MihonCompatKit        # bash
scripts\windows_dev_test.bat Packages\MihonCompatKit test # Windows cmd
swift run --package-path Packages/MihonCompatKit compat-audit inspect some-extension.apk
```

## Test corpus (real extensions)

```bash
scripts/fetch_corpus.sh   # downloads APKs from the live Keiyoushi store
```

Corpus APKs are gitignored (third-party binaries); the script pins the
package list and records provenance in `Tests/corpus/manifest.json`.
