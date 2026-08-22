# Kami Continuation Handoff

Last updated: 2026-08-22 (America/Lima)

This is the durable continuation point for moving Kami development to another
computer. The previous GLM 5.3 session stopped because its usage quota was
exhausted, not because the repository or build failed. Its intended Phase 2
work was recovered, completed, verified, and pushed.

## Start here

- Repository: <https://github.com/taizaki69/Kami>
- Visibility: private
- Default branch: `main`
- Code and documentation baseline before this handoff: `4e50e6380c864e09205eb753c3ed7037780f9897`
- Original Phase 2 baseline: `6f9de0719f057646e228f14620806326840e5c75`
- Expected state after cloning: clean `main`, tracking `origin/main`

Always continue from the latest `origin/main`. The SHA above identifies the
known-good implementation state; the commit adding this handoff follows it and
contains documentation only.

## Clone and restore the workspace

Because the repository is private, authenticate the new computer first:

```bash
gh auth login
gh repo clone taizaki69/Kami
cd Kami
git switch main
git pull --ff-only
git status --short --branch
```

The final status command should show `main...origin/main` with no tracked
changes.

### macOS: full iOS development

Requirements: Xcode 15 or newer and xcodegen.

```bash
brew install xcodegen
bash scripts/bootstrap.sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package_ipa.sh
```

The app target is iOS 17.0. The Swift packages retain an iOS 16.0 minimum.
`Kami.ipa` is unsigned; use only credentials owned by the developer when
signing or installing it.

### Windows or Linux: portable packages

The compatibility layer is portable. It was verified with Swift 6.3.3 on
Windows; Swift 5.9 or newer is the intended minimum.

```bash
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
swift build --package-path Packages/MihonCompatKit -c release --product compat-audit
```

On Windows, prefer the checked-in helper when the Swift driver behaves
inconsistently from the active shell. It currently expects VS Build Tools 18
and the user-local Swift 6.3.3 toolchain paths shown in the script; adjust them
if the new machine installs different versions:

```bat
scripts\windows_dev_test.bat Packages\MihonCompatKit test
```

The iOS app itself still requires macOS and Xcode.

### Restore the real-extension corpus

The APK corpus is intentionally not stored in Git:

```bash
bash scripts/fetch_corpus.sh
```

The script downloads three immutable Keiyoushi release assets and verifies
their SHA-256 values against `Tests/corpus/manifest.json`. On Windows, run it
from Git Bash or WSL, or let Swift CI fetch the corpus.

Do not copy these generated or ignored paths between computers:

- `Packages/KamiCore/.build/`
- `Packages/MihonCompatKit/.build/`
- generated `.xcodeproj`, `DerivedData/`, `dist/`, or IPA files

`Tests/corpus/*.apk` can be regenerated with the fetch script. The ignored
`Tests/corpus/index.pb` is not required by the pinned APK execution suite.

Never commit `.env` files, Apple certificates, provisioning profiles, P12
files, passwords, cookies, or signing credentials.

## Known-good verification checkpoint

At the implementation baseline:

| Check | Result |
|---|---|
| MihonCompatKit and KamiCore | 54 Swift tests passed |
| Real APK execution | Akuma and MangaDex constructors passed |
| BatCave execution | Exact `getBaseUrl`, `getLang`, `getName`, and `getId` assertions passed |
| Swift CI | [successful run 32582952981](https://github.com/taizaki69/Kami/actions/runs/32582952981) |
| iOS Simulator and unsigned device builds | [successful run 32582953090](https://github.com/taizaki69/Kami/actions/runs/32582953090) |
| Unsigned IPA packaging | [successful run 32582953062](https://github.com/taizaki69/Kami/actions/runs/32582953062) |
| Repository integrity | clean worktree and `git fsck --full` passed |

The referenced runs produced `compat-audit-macos` and `Kami-unsigned-ipa`.
GitHub artifacts expire; rerun the corresponding workflow if they are no
longer available.

## What Phase 2 completed

The range from `6f9de07` through `4e50e63` contains these checkpoints:

```text
743690d fix: repair CI compilation and preserve library state
28f9430 fix: resolve macOS package diagnostics
b88cf79 fix: handle invalid extension indexes in app
60daa81 fix: execute real extension dex correctly
270843d fix: harden untrusted extension parsing
9fb7d87 fix: surface oversized repository responses
1ae9e14 docs: record measured runtime and CI status
4e50e63 docs: align architecture with runtime status
```

The work includes:

- SQLite binding/step error handling and preservation of manga library state,
  chapter IDs, read state, bookmarks, and progress during refreshes.
- Correct DEX 35c register ordering, final-register argument placement, shared
  call-tree budgets, call-depth limits, exceptions, additional opcode
  families, Java numeric behavior, and bounds-safe host arguments.
- Minimal Object, String, StringBuilder, Kotlin Intrinsics, HttpSource, and
  ParsedHttpSource construction surfaces.
- Bounded ZIP/ZIP64, DEFLATE, zlib, gzip, AXML, protobuf, and DEX parsing with
  checksums, structural checks, count/size limits, and malformed-prefix tests.
- Repository index limits, typed missing-response errors, and an APK response
  acceptance limit.
- Immutable, SHA-256-locked real APK tests in Swift CI.
- Honest documentation of the measured M1 runtime rather than claiming full
  extension compatibility.

The current DEX parser accepts formats 035 and 037 through 040. Format 036 is
not a standard supported revision, and 041 is deliberately rejected because
its container/header contract differs from the implemented 112-byte format.

## What is proven, and what is not

Proven today:

- Real store-index parsing for protobuf and legacy JSON formats.
- Bounded APK archive, manifest, and DEX structural parsing.
- Compatibility analysis and the `compat-audit` CLI.
- Shallow execution of the exact pinned real-extension methods listed above.
- Native MangaDex browsing through the existing `KamiSource` implementation.
- Simulator/device compilation and creation of a real unsigned IPA.

Not proven or implemented:

- An interpreted extension completing popular/search, details, chapters, and
  pages through `KamiSource`.
- General OkHttp, Jsoup, coroutine, preferences, cookie, or WebView bridges.
- Full DEX opcode coverage, verification, or prototype-aware dispatch.
- APK signer authentication and update identity binding.
- A signed installation on a physical iPhone or iPad.
- Production compatibility telemetry or a declared repository license.

Do not describe constructor/getter execution as end-to-end extension support.

## Security and trust boundary

A completed security review of the executable seven-commit Phase 2 diff found
no vulnerability introduced or newly made reachable by that range. That result
does not mean the runtime is production-complete.

Preserve these security facts:

- Repository indexes, redirects, APKs, ZIP/AXML/protobuf/DEX structures, DEX
  bytecode, source responses, and backup data are hostile input.
- Interpreted code may reach native capabilities only through explicit,
  deny-by-default `HostBridge` registrations.
- Checksums and locked hashes detect corruption or substitution relative to a
  known fixture; they do not authenticate an APK publisher.
- Do not register a downloaded APK for execution until issue #3 provides a
  persisted signer trust result.
- Never load Android native `.so` files.
- Keep cookies, preferences, network policy, and future WebView state scoped
  to one source; do not expose app-global secrets to interpreted code.
- Preserve shared instruction/call-depth/array limits when adding opcodes.
- SQL values must remain parameter-bound and all persistence must remain
  actor-serialized and transactional.

Known pre-existing hardening gaps that were not diff-introduced findings:

- URLSession response limits are checked after full-body buffering.
- External-list/APK URL scheme, redirect, and destination policy is broad.
- ZIP/DEX/string processing lacks a complete aggregate resource budget.
- Catch-handler parsing retains unchecked large ULEB64-to-`Int` conversions.
- DEX and host dispatch are class-plus-name based rather than full-prototype
  based, although no current privileged bridge method creates an exploit sink.
- Instruction counts do not price expensive StringBuilder copying or every
  allocation cost.

Address these before treating arbitrary downloaded extensions as safe.

## Open work and issue tracker

| Priority | Issue | Purpose |
|---|---|---|
| P0 | [#1 Complete DEX opcode coverage and verifier semantics](https://github.com/taizaki69/Kami/issues/1) | Full prototypes, verification, differential semantics, and typed failures |
| P0 | [#2 Build the first end-to-end interpreted Mihon source](https://github.com/taizaki69/Kami/issues/2) | One real APK through search/popular, details, chapters, pages, and `KamiSource` |
| Security gate | [#3 Verify APK signing identity](https://github.com/taizaki69/Kami/issues/3) | Required before downloaded APK execution |
| Diagnostics | [#4 Add privacy-safe compatibility telemetry](https://github.com/taizaki69/Kami/issues/4) | Deterministic, redacted unresolved-surface reports |
| Distribution | [#5 Add the declared Apache-2.0 license](https://github.com/taizaki69/Kami/issues/5) | Requires owner confirmation before adding the license |

The rest of the product backlog is in `TODO.md`.

## Recommended next implementation sequence

1. Work only with the pinned local corpus while the signer gate is absent.
2. Start issue #1 by changing public and internal method lookup to use the
   declaring class, method name, return type, and parameter descriptors.
3. Add verifier checks for code-item geometry, branch/payload targets,
   register types, exception handler conversions, and invoke word counts.
4. Add aggregate parser/runtime resource accounting and streaming or
   delegate-limited repository downloads.
5. Pick one pinned extension for issue #2 and record the first precise missing
   class/method/opcode at each operation stage. Implement reusable Java,
   Kotlin, tachiyomix, OkHttp, and Jsoup behavior; do not add
   extension-specific shortcuts.
6. Expose the interpreted source through the existing `KamiSource` contract
   only after exact popular/search, details, chapters, and pages tests pass.
7. Implement issue #3 before enabling execution of arbitrary repository
   downloads or updates.
8. Add issue #4 diagnostics as local, deterministic, redacted output so the
   compatibility corpus can grow from reproducible failures.

Every new runtime capability should arrive with a synthetic malformed fixture,
an exact real-APK assertion when reachable, and CI coverage.

## Important files

| Area | Entry point |
|---|---|
| Current status | `README.md`, `TODO.md`, `ARCHITECTURE.md` |
| Build and signing | `BUILDING.md`, `docs/IPA_BUILD.md`, `project.yml` |
| Runtime contract | `docs/EXTENSION_RUNTIME.md` |
| Measured compatibility | `docs/EXTENSION_COMPATIBILITY_MATRIX.md` |
| APK and archive parsing | `Packages/MihonCompatKit/Sources/MihonCompatKit/APK/` |
| DEX parser | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/DexFile.swift` |
| Interpreter | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexInterpreter.swift` |
| Native capability boundary | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/HostBridge.swift` |
| Repository client | `Packages/MihonCompatKit/Sources/MihonCompatKit/Repository/ExtensionRepository.swift` |
| App source seam | `Packages/MihonCompatKit/Sources/MihonCompatKit/Models/CompatModels.swift` (`KamiSource`) |
| Persistence | `Packages/KamiCore/Sources/KamiCore/Database/` |
| Corpus lock/fetch | `Tests/corpus/manifest.json`, `scripts/fetch_corpus.sh` |
| Workflows | `.github/workflows/ci.yml`, `ios-build.yml`, `ipa.yml` |

## Before pushing the next implementation

Run the checks appropriate to the active computer, then inspect the diff:

```bash
git diff --check
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
git status --short --branch
```

For app changes, also generate and compile both Simulator and unsigned generic
device targets on macOS. After pushing, require Swift CI, iOS Build, and IPA
Package to finish successfully for the exact head SHA.
