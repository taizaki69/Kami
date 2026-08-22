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
- Current verified runtime implementation baseline: `4d042c99a62536fbd894966286a1de7a93c5d0be`
- Previous exact-dispatch/class-initialization baseline: `05720d24d46d13b21e25dee2b95737b59fa65a9d`
- Code and documentation baseline before the original handoff: `4e50e6380c864e09205eb753c3ed7037780f9897`
- Original Phase 2 baseline: `6f9de0719f057646e228f14620806326840e5c75`
- Expected state after cloning: clean `main`, tracking `origin/main`

Always continue from the latest `origin/main`. The current runtime SHA above is
the known-good executable state; the commit updating this handoff follows it
and contains documentation only.

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
| MihonCompatKit | 63 Swift tests passed; KamiCore also passed in macOS CI |
| Real APK constructors | Akuma, MangaDex, and BatCave passed |
| Request-model regressions | 2 focused tests cover request construction, duration/cache conversion, URL scheme rejection, CRLF-header rejection, and body bounds |
| BatCave execution | Exact metadata getters passed; popular path constructs the expected POST request and stops at the `awaitSuccess` transport seam |
| Swift CI | [successful run 32587746756](https://github.com/taizaki69/Kami/actions/runs/32587746756) |
| iOS Simulator and unsigned device builds | [successful run 32587746746](https://github.com/taizaki69/Kami/actions/runs/32587746746) |
| Unsigned IPA packaging | [successful run 32587746752](https://github.com/taizaki69/Kami/actions/runs/32587746752) |
| Repository integrity | clean worktree and `git fsck --full` passed |

The referenced runs produced `compat-audit-macos` and `Kami-unsigned-ipa`.
GitHub artifacts expire; rerun the corresponding workflow if they are no
longer available.

## What the latest continuation completed

Commit `4d042c9` advances the pinned BatCave APK through transport-neutral
request construction without performing network I/O:

- Public, `Sendable`, equatable `CompatHTTPRequest`, header, form-field, body,
  and cache-policy values live in
  `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPRequest.swift`.
- The exact host allow-list now models the BatCave-reached OkHttp surface:
  per-source `NetworkHelper`/client identity, required default interceptors,
  client cloning, compression-interceptor setup, headers, HTTP(S) URLs, form
  and text bodies, cache control, request builders/getters, and inert calls.
- Request inputs are bounded: URLs are HTTP(S)-only and at most 8 KiB; header
  names/values reject invalid controls and CRLF injection; header/form
  collections and aggregate raw bytes are capped; text bodies are capped at
  1 MiB. These are construction limits, not a substitute for future response
  streaming limits.
- Kotlin duration unit fields and the exact duration conversions reached by
  cache-control setup are modeled. Compiler-only
  `SpillingKt.nullOutSpilledVariable` is also covered.
- `HostBridge.lastPreparedRequest` exposes only the inert request handed to
  `OkHttpClient.newCall`; it does not send it.
- The real BatCave `getPopularManga` assertion proves this exact request:

  ```text
  POST https://batcave.biz/comix/
  dlenewssortby=rating
  dledirection=desc
  set_new_sort=dle_sort_cat_1
  set_direction_sort=dle_direction_cat_1
  ```

- Execution then stops exactly at the deliberately unresolved method
  `Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;->awaitSuccess(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;`.
  This is the transport/coroutine boundary, not a successful popular-manga
  response.

The two new focused request tests and eight pinned real-extension tests are
part of the 63-test MihonCompatKit suite. All three workflows linked above
passed for the exact implementation SHA.

## What the preceding runtime continuation completed

Commit `05720d2` advances the same pinned BatCave APK from shallow getters to a
reproducible pre-request execution path:

- DEX and host methods are keyed by exact declaring class, name, parameter
  descriptors, return descriptor, and static/instance kind. Name-only public
  calls reject overload ambiguity.
- Invoke validation checks register-word counts, wide pairs, caller
  `outs_size`, logical argument categories, return categories, and encoded
  static/instance consistency. Diagnostics and traces carry canonical method
  signatures.
- DEX class initialization runs once before static use/allocation, initializes
  DEX superclasses first, retains failure state, and shares the entry call's
  instruction budget.
- The deny-by-default host surface now includes only exact signatures proven by
  synthetic or pinned-corpus paths: confined source-field reflection, core
  Kotlin result/lazy/pair/coroutine primitives, primitive boxes, atomics,
  bounded collections and iteration, regex/date construction, and Mihon
  filters.
- `compat-audit methods <apk> [text-or-index]` prints canonical first-DEX
  method identities, making each next missing ABI call reproducible.
- BatCave's real constructor succeeds. Its real `getPopularManga` path crossed
  filters and iteration to the former `FormBody.Builder` boundary; commit
  `4d042c9` subsequently completed the pure request layer described above.

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
- Exact execution of the pinned constructors/getters listed above and
  BatCave's interpreted popular path through exact pure request construction
  to the `awaitSuccess` transport boundary.
- Bounded, transport-neutral OkHttp request values with no live-network side
  effects, including the exact pinned BatCave POST assertion.
- Native MangaDex browsing through the existing `KamiSource` implementation.
- Simulator/device compilation and creation of a real unsigned IPA.

Not proven or implemented:

- An interpreted extension completing popular/search, details, chapters, and
  pages through `KamiSource`.
- Extension HTTP transport, response/response-body/Okio models, coroutine
  suspension/resumption across async transport, Jsoup, preferences, cookies,
  or WebView bridges. The current OkHttp subset is request-only.
- Full DEX opcode coverage, a pre-execution verifier, or dynamic
  virtual/interface target selection across receiver hierarchies.
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
- Dynamic virtual/interface dispatch does not yet walk the receiver hierarchy;
  exact prototype identity and static/instance kind are enforced.
- Instruction counts do not price expensive StringBuilder copying or every
  allocation/host-collection operation cost.

Address these before treating arbitrary downloaded extensions as safe.

## Open work and issue tracker

| Priority | Issue | Purpose |
|---|---|---|
| P0 | [#1 Complete DEX opcode coverage and verifier semantics](https://github.com/taizaki69/Kami/issues/1) | Remaining verifier, dynamic dispatch, opcode, and differential semantics work |
| P0 | [#2 Build the first end-to-end interpreted Mihon source](https://github.com/taizaki69/Kami/issues/2) | One real APK through search/popular, details, chapters, pages, and `KamiSource` |
| Security gate | [#3 Verify APK signing identity](https://github.com/taizaki69/Kami/issues/3) | Required before downloaded APK execution |
| Diagnostics | [#4 Add privacy-safe compatibility telemetry](https://github.com/taizaki69/Kami/issues/4) | Deterministic, redacted unresolved-surface reports |
| Distribution | [#5 Add the declared Apache-2.0 license](https://github.com/taizaki69/Kami/issues/5) | Requires owner confirmation before adding the license |

The rest of the product backlog is in `TODO.md`.

## Recommended next implementation sequence

1. Work only with the pinned local corpus while the signer gate is absent.
2. Preserve exact prototype/staticness dispatch and use `compat-audit methods`
   plus canonical unresolved diagnostics for every new bridge decision.
3. Continue issue #1 with dynamic receiver-hierarchy dispatch and verifier
   checks for code-item geometry, branch/payload targets, register types, and
   exception-handler conversions. Invoke word-count checks are already in.
4. Add aggregate parser/runtime resource accounting and streaming or
   delegate-limited repository downloads.
5. Continue issue #2 from the exact `OkHttpExtensionsKt.awaitSuccess` seam.
   First define an injectable per-source transport contract consuming
   `CompatHTTPRequest`; production transport must use URLSession with redirect
   policy, cancellation, timeouts, response-header/body limits, redaction, and
   isolated cookies. Keep the pinned test on a deterministic fake transport;
   do not make live requests in the test suite.
6. Model OkHttp `Response`/`ResponseBody`, the reached Okio surface, and proper
   coroutine suspension/resumption. Do not register `awaitSuccess` as an
   unconditional fake success or block the interpreter thread on URLSession.
   Continue recording the next exact signature at every boundary.
7. Add response parsing (Jsoup/serialization) and prove BatCave popular output,
   then search, details, chapters, and pages, before exposing the interpreted
   source through the existing `KamiSource` contract.
8. Expose the interpreted source through the existing `KamiSource` contract
   only after exact popular/search, details, chapters, and pages tests pass.
9. Implement issue #3 before enabling execution of arbitrary repository
   downloads or updates.
10. Add issue #4 diagnostics as local, deterministic, redacted output so the
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
| Pure HTTP request values | `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPRequest.swift` |
| Request-model regressions | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/CompatHTTPRequestTests.swift` |
| Real APK execution frontier | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/RealExtensionExecutionTests.swift` |
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
