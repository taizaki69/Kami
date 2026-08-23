# Kami Continuation Handoff

Last updated: 2026-08-23 (America/Lima)

This is the durable continuation point for moving Kami development to another
computer. The previous GLM 5.3 session stopped because its usage quota was
exhausted, not because the repository or build failed. Its intended Phase 2
work was recovered, completed, verified, and pushed.

## Start here

- Repository: <https://github.com/taizaki69/Kami>
- Visibility: private
- Default branch: `main`
- Current code/test checkpoint: `4eca3b2866b8fe4088956d793dd31ec780bde2a3`
- Previous text-search baseline: `8d496330d1c5fd9e413164d12902d7b7cdb97eb7`
- Bounded HTML/popular parsing baseline: `f55a695f57aba7685fa51b563107f277e7503d37`
- Previous macOS test-compiler portability baseline: `e5988c34692e795180f020dee67a4a90a993ee80`
- Current async transport/runtime implementation baseline: `6cb46b5ccbe600ca93847fdd270f8bfa02ecc690`
- Previous isolated HTTP transport baseline: `e58bf8e83bbc562e240f0f507f76cd8c42655e1c`
- Previous opcode-inventory baseline: `1293540`
- Previous parsed-DEX dispatch baseline: `f36a07a0a423c39287ae4efe37376c1eab459a35`
- Previous resolved-reference/typed-catch baseline: `b079d6912fc08b89fab4d654b92ada6d07ff73f0`
- Previous exact primitive/constructor-state baseline: `10bf770d61ebe1f6bb5dd9d13ade63853cdbffd8`
- Previous register-category baseline: `7ce3c812d5eca159a28d680591a45a72ff325956`
- Previous exception-verifier baseline: `66d41261e4cfa70bea2fd9a89a2f0dcdb670eff6`
- Previous structural-verifier baseline: `284b24dc2b7bec838afed5b6a2c9ea07df8b8f0b`
- Previous receiver-directed dispatch baseline: `057169640b43c516455f753ae3efd81e3db02e61`
- Previous request-model runtime baseline: `4d042c99a62536fbd894966286a1de7a93c5d0be`
- Previous exact-dispatch/class-initialization baseline: `05720d24d46d13b21e25dee2b95737b59fa65a9d`
- Code and documentation baseline before the original handoff: `4e50e6380c864e09205eb753c3ed7037780f9897`
- Original Phase 2 baseline: `6f9de0719f057646e228f14620806326840e5c75`
- Expected state after cloning: clean `main`, tracking `origin/main`

Always continue from the latest `origin/main`. The current runtime SHA above is
the known-good executable state; the commit updating this handoff follows it
and contains documentation only.

## Current resume point

Stop state on 2026-08-23 (America/Lima):

- Commit `f55a695` is pushed to `main`. It pins SwiftSoup 2.9.6 and places a
  resource-bounded HTML5/CSS layer behind the exact Jsoup methods reached by the
  pinned BatCave APK. Limits cover input bytes, DOM nodes/depth/attributes,
  selector length/results/cumulative work, and extracted strings.
- The host bridge now supplies the reached `Document`, `Element`, `Elements`,
  `SManga`, `MangasPage`, and `HttpSource.setUrlWithoutDomain` behavior. The
  real BatCave popular worker sends its exact POST, crosses the deterministic
  async transport, parses production selectors, and returns an exact two-entry
  app-facing `MangasPage` with relative URLs and pagination.
- Commit `8d49633` is pushed to `main`. BatCave's real nonblank text-search worker
  now trims and Java-form-encodes a page-2 query, builds the exact GET with its
  600-second cache policy, and parses the response into the expected no-next-page
  manga result. The R8-renamed worker is invoked directly because its external
  KeiSource superclass bridge is not implemented yet.
- Commit `4eca3b2` is pushed to `main`. BatCave's public latest-updates operation
  builds the exact cached page-3 GET and returns a paginated `MangasPage`. Its
  real generated manga-details worker builds the cached detail GET and returns
  URL, title, thumbnail, publisher/year description, author, artist, genres,
  and status. The shared bridge now supplies bounded Kotlin default collection
  joining plus modern Jsoup direct-child `:has(> ...)` and element-relative
  `> ...` selector semantics missing from SwiftSoup 2.9.6.
- All 155 MihonCompatKit tests pass locally on Windows/Swift 6.3.3, including 13
  pinned real-extension paths, 6 focused HTML/parser-limit tests, bounded Java
  URL-encoding and Kotlin collection-joining regressions, and 4 async
  interpreter/transport tests. A clean KamiCore dependency build/test and the
  optimized MihonCompatKit/`compat-audit` build also pass.
- The earlier `6cb46b5` async runtime still captures nested DEX frames, awaits
  without blocking, resumes inside-out with shared budgets and typed handlers,
  propagates cancellation, and exposes bounded OkHttp response/body values.
- A real-APK regression still proves a 503 response reaches Mihon's exact
  `HttpException(code: 503)`.
- The first macOS Swift CI attempt exposed only a compiler type-check timeout in
  one large test-fixture expression, fixed by `e5988c3`. The newest `4eca3b2`
  Swift CI [32657995346](https://github.com/taizaki69/Kami/actions/runs/32657995346),
  iOS Build [32657995294](https://github.com/taizaki69/Kami/actions/runs/32657995294),
  and IPA Package [32657995329](https://github.com/taizaki69/Kami/actions/runs/32657995329)
  jobs all have zero steps and the explicit account payment/spending-limit
  annotation. Resolve Actions billing and rerun all three workflows before
  treating macOS/iOS verification as current. The preceding `6cb46b5` iOS
  Build and IPA Package runs did pass.
- GitHub CLI is installed and authenticated as `taizaki69`; repository and
  workflow access were working. No authentication setup should be needed on
  this computer.
- The three pinned APKs are present locally and still match the lock file:
  Akuma 1.4.10, MangaDex 1.4.212, and BatCave 1.6.9.
- Issue #1 has the completed dispatch-milestone evidence in
  [progress comment 5384204450](https://github.com/taizaki69/Kami/issues/1#issuecomment-5384204450)
  and remains open intentionally.
- Issue #2 has the latest/details checkpoint in
  [progress comment 5387724350](https://github.com/taizaki69/Kami/issues/2#issuecomment-5387724350)
  and remains open for chapters, pages, and `KamiSource` exposure.

### Next milestone: BatCave chapters and pages

Popular, paginated text search, latest updates, and core manga details now
return exact compatibility models. Drive the chapter branch from the pinned
source's real generated methods. Its next measured flow is:

```text
fetchMangaUpdate
  -> optional cached details GET + parseMangaDetails(Document)
  -> parseChapterList(Document)
  -> script data extraction + kotlinx serialization
  -> SChapter fields + date parsing
  -> SMangaUpdate

getPageList(SChapter)
  -> chapter request + JSON response
  -> Page values
```

Use deterministic offline HTML and continue accepting only exact canonical
signatures measured from the locked APK. First record the exact unresolved
signature reached by chapter parsing; do not prebuild a broad serialization
runtime. The optional related-manga memo JSON branch in details is also still
unproven and can be added when its reusable serialization surface overlaps the
chapter work. Record each next exact gap before implementing it.

Do not enable arbitrary downloaded APK execution while the signer gate in
issue #3 remains open. Keep `HostBridge` deny-by-default and never execute
extension native libraries.

Start with:

```bash
git switch main
git pull --ff-only
git status --short --branch
swift test --package-path Packages/MihonCompatKit
swift build --package-path Packages/MihonCompatKit -c release --product compat-audit
```

On this Windows checkout, use the checked-in helper for the test command if
needed. Keep execution offline and limited to `Tests/corpus/*.apk`; the APK
signer gate in issue #3 is still open.

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
scripts\windows_dev_test.bat Packages\MihonCompatKit release
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
| MihonCompatKit | 155 Swift tests passed locally on Windows/Swift 6.3.3; exact-head macOS CI is blocked before dispatch by Actions billing |
| Optimized package build | `scripts\windows_dev_test.bat Packages\MihonCompatKit release` compiled and linked SwiftSoup, MihonCompatKit, and `compat-audit.exe` in 211.97 seconds |
| Real APK constructors | Akuma, MangaDex, and BatCave passed |
| Structural verifier | 9 focused regressions cover instruction geometry, branch/fallthrough boundaries, and aligned, bounded, correctly typed payloads and switch targets |
| Exception/control verifier | 13 focused regressions cover strict try/catch decoding, resolved `Throwable` validation, typed handler state/execution, and AOSP branch/result/exception-entry rules |
| Register dataflow verifier | 21 focused regressions cover dead-code bounds, parameter seeding, common-supertype joins, polymorphic constants, exact primitive/wide/reference assignments, array covariance, result/invoke types, wide-pair clobbering, exception edges, and constructor/uninitialized-object state |
| Runtime reference semantics | 4 focused regressions cover resolved and unresolved typed-catch dispatch plus hierarchy-aware `check-cast` and `instance-of` |
| Binary opcode semantics | 1 focused regression covers AOSP operation/type-major ordering across int, long, float, double, and `/2addr` forms |
| Method resolution and receiver dispatch | 15 focused regressions cover virtual/class override selection, lexical normal/range class-super dispatch, inherited/maximally-specific interface defaults, abstract masking, default conflicts, DEX 037 interface-super gating, strict interface receivers, typed linkage failures, and conservative unresolved boundaries |
| Request/model host regressions | 4 focused tests cover request construction, duration/cache conversion, URL scheme rejection, CRLF-header rejection, body bounds, Java URL encoding, and bounded Kotlin default collection joining |
| HTTP transport regressions | 8 focused tests cover source isolation, bounded deterministic encoding, redirect secret stripping/downgrade rejection, streamed response limits, cancellation, and cookie scope |
| Async interpreter/response regressions | 4 focused tests cover nested frame resumption, sync-entry diagnostics, typed DEX handler re-entry, cancellation, injected transport, charset decoding, one-shot reads, and close state |
| HTML/selector hardening | 6 focused tests cover BatCave CSS/URL semantics, modern direct-child relative selectors, input, base-URL, node, depth, attribute, selector length/result/work, and extracted-string limits |
| BatCave execution | Exact metadata getters pass; popular, paginated text search, and latest updates build exact requests and parse exact `MangasPage` values; core details return exact `SManga` fields; a 503 maps to `HttpException(code: 503)` |
| Swift CI | Latest `4eca3b2` [run 32657995346](https://github.com/taizaki69/Kami/actions/runs/32657995346) was blocked before runner dispatch by Actions billing; the job has zero steps and the explicit billing annotation |
| iOS Simulator and unsigned device builds | `6cb46b5` passed [run 32655420894](https://github.com/taizaki69/Kami/actions/runs/32655420894); latest `4eca3b2` [run 32657995294](https://github.com/taizaki69/Kami/actions/runs/32657995294) was blocked before dispatch by Actions billing |
| Unsigned IPA packaging | `6cb46b5` passed [run 32655420893](https://github.com/taizaki69/Kami/actions/runs/32655420893); latest `4eca3b2` [run 32657995329](https://github.com/taizaki69/Kami/actions/runs/32657995329) was blocked before dispatch by Actions billing |
| Repository integrity | clean worktree and `git fsck --full` passed |

The successful iOS/IPA runs validate the `6cb46b5` async runtime implementation
and produced `Kami-unsigned-ipa`. Commits `e5988c3`, `f55a695`, `8d49633`, and
`4eca3b2` have local full-suite evidence only until GitHub Actions billing is restored.
Rerun Swift CI, iOS Build, and IPA Package for the latest exact checkpoint.

## What the latest continuation completed

Commit `f55a695` crosses the measured Jsoup boundary without pretending the
source is end-to-end complete:

- SwiftSoup 2.9.6 is exactly pinned as the Swift 5.9-compatible HTML5/CSS engine
  and recorded under its MIT license.
- Kami owns independent untrusted-input limits around parsing, DOM shape,
  selector work/results, and extracted strings.
- Exact Jsoup document/element/elements registrations plus the reached
  `SManga`/`MangasPage` model surface let BatCave's real parser return an exact
  app-facing popular page from deterministic HTML.
- Five focused hardening tests and the pinned real-APK result bring the suite to
  148 tests.

Commit `8d49633` then adds the measured Kotlin trim and Java UTF-8 form-encoding
surface. The real BatCave text-search worker proves its exact page-2 GET, cache
policy, parsed manga fields, and false pagination result; the focused encoder
test and pinned search path bring the suite to 150 tests.

Commit `4eca3b2` adds the public latest-updates and core manga-details paths:

- The pinned APK builds the exact cached page-3 latest GET and returns the
  expected paginated `MangasPage` from deterministic production-shaped HTML.
- Its real generated details worker builds the exact cached detail GET and
  returns URL, title, thumbnail, publisher/year description, author, artist,
  genres, and ongoing status.
- A bounded Kotlin `joinToString$default` shim supplies genre joining and rejects
  oversized output. The SwiftSoup adapter supplies the modern Jsoup
  direct-child relative-selector behavior reached by details while charging
  every compatibility pass against the cumulative selector budget.
- Two real-APK paths and three focused regressions bring the suite to 155 tests.

Earlier commit `6cb46b5` crossed the asynchronous extension HTTP boundary:

- `DexInterpreter.callAsync` snapshots exact nested frames at async host
  invocations, awaits without blocking, resumes inside-out, preserves the
  shared instruction budget, and supports repeated suspension. A thrown DEX
  value re-enters the typed handler covering the original invoke instruction;
  Task cancellation becomes `VMError.cancelled`.
- `HostBridge` has exact sync and async method registries. Synchronous `call`
  reports `asyncExecutionRequired` instead of leaking an internal suspension.
  No async network method exists unless a source-scoped transport is injected.
- Mihon's `await` and `awaitSuccess` execute the prepared request. Transport
  failures become redacted `IOException` values; `awaitSuccess` accepts only
  2xx and otherwise throws a modeled Mihon `HttpException` with its code.
- Bounded `Response`, `ResponseBody`, `Headers`, and `BufferedSource` host values
  expose the reached status/header/body/charset/one-shot read behavior using
  only the already bounded transport response.
- Four focused async regressions and two pinned BatCave paths brought that
  historical suite to 143 tests and moved the real-APK frontier from
  `awaitSuccess` to `JsoupExtensionsKt.asJsoup$default`.

Commit `e5988c3` then splits one compound DEX test-fixture expression so the
macOS compiler can type-check it without timing out; it makes no runtime
semantic change.

Commit `e58bf8e` immediately before it supplies the isolated production
URLSession transport: per-source actor ownership, redirect/timeout/request and
response limits, streaming response-body enforcement, cancellation, and an
in-memory source-isolated cookie jar.

## What the preceding dispatch continuation completed

Commit `f36a07a` completes parsed-DEX class-super and interface-default method
resolution for the current DEX runtime milestone:

- A shared method resolver now selects normal virtual methods from the runtime
  class chain, lets class declarations override interface defaults, and applies
  maximally specific interface-default rules across parsed interface graphs.
  Abstract subinterfaces mask parent defaults, unrelated concrete defaults
  conflict, and incomplete external relationships or native/no-code methods
  remain unresolved instead of being guessed.
- Class `invoke-super` and `invoke-super/range` dispatch relative to the lexical
  caller's direct superclass, so a grandparent method reference correctly
  reaches an override in the immediate parent. DEX 037+ interface
  `invoke-super` searches only the referenced interface graph and ignores class
  overrides and sibling interfaces.
- The verifier now checks class/interface invoke kinds, static/direct/virtual
  method-list placement, interface invoke version gates, locally resolvable
  method references, and lexical supertype relationships. Unknown external
  targets continue to soft-verify.
- Resolved abstract, missing, conflicting-default, and known non-implementing
  receiver failures surface as typed `AbstractMethodError`,
  `NoSuchMethodError`, or `IncompatibleClassChangeError` values.
- `DexFile` exposes its numeric format version. The controlled DEX builder now
  emits multiple sorted class definitions, selectable 035/037-040 magic,
  per-class interfaces/fields/methods, explicit access flags, and abstract or
  native no-code declarations.
- Thirteen new regressions bring MihonCompatKit to 126 passing tests, including
  91 interpreter tests and all eight pinned real-extension paths. The debug and
  release compatibility builds plus the KamiCore dependency build/test pass on
  Windows/Swift 6.3.3; Swift CI, both iOS targets, and IPA packaging pass on the
  exact SHA.

Remaining issue #1 work is broader external class-graph and super/default
resolution, remaining opcode coverage, and differential AOSP fixtures.

## What the preceding resolved-reference continuation completed

Commit `b079d69` completes the resolved-reference and typed-catch portion of the
DEX verifier/runtime milestone:

- A shared conservative hierarchy resolves parsed DEX superclasses and
  interfaces plus the bounded Java/Kotlin classes modeled by `HostBridge`.
  Assignability is tri-state so absent external library graphs soft-verify
  instead of causing speculative rejection.
- Reference-array covariance, exact primitive-array compatibility, and
  common-superclass joins now preserve useful verifier types. Explicit external
  superclasses named by parsed DEX definitions remain part of those joins even
  when their own class bodies are outside the APK.
- Returns, invoke receivers/arguments, constructor receivers, field receivers
  and values, array writes, filled arrays, and throws reject resolved unrelated
  reference types. Ordinary interface assignment retains ART's non-strict
  verifier behavior; runtime checks use strict hierarchy traversal.
- Resolved catch types must derive from `Throwable`. Handler entry state now
  gives `move-exception` the common resolved caught type instead of always
  widening to `Throwable`.
- `check-cast`, `instance-of`, reflection instance checks, and typed exception
  dispatch use the same hierarchy. Known bad casts raise a typed
  `ClassCastException`, `throw null` produces `NullPointerException`, synthetic
  host failures are normalized to typed exception objects, and an unresolved
  external thrown value can reach `catch (Throwable)` without matching a
  speculative narrower catch.
- Ten new regressions bring MihonCompatKit to 113 passing tests, including 78
  interpreter tests and all eight pinned real-extension paths. The explicit
  compatibility build and KamiCore dependency build/test pass on Windows/Swift
  6.3.3; Swift CI, both iOS targets, and IPA packaging pass on the exact SHA.

Commit `f36a07a` subsequently completed parsed-DEX interface-default and
lexical class/interface `invoke-super` behavior. Broader resolution beyond the
parsed graph remains open.

## What the preceding exact-type continuation completed

Commit `10bf770` completes the exact primitive-family and uninitialized-object
portion of the DEX register verifier:

- The register lattice now follows ART's concrete type families: bounded
  polymorphic 32-bit constants; boolean, byte, char, short, int, and float;
  distinct long/double/constant-wide pairs; initialized references;
  allocation-site-specific uninitialized references; and uninitialized
  constructor `this`. Undefined and conflict states remain explicit.
- Numeric opcodes, comparisons, branches, arrays, fields, calls, returns, and
  conversions now require and produce their exact primitive family. Constants
  remain usable as int/float or long/double until an operation resolves them,
  matching the verifier behavior documented by ART's
  [`RegType`](https://android.googlesource.com/platform/art/+/master/runtime/verifier/reg_type.h).
- `new-instance` produces an allocation-identity value rather than an ordinary
  reference. Only object moves and the matching direct constructor call may
  consume that state; successful construction initializes every alias.
  Ordinary calls, fields, arrays, casts, monitors, throws, and returns reject
  uninitialized objects.
- Instance constructors receive uninitialized `this`, may access their own
  fields before the super/this call, and cannot return until a direct
  constructor call initializes all aliases. Constructor calls on already
  initialized references and constructor names invoked with the wrong opcode
  are rejected. These rules follow ART's
  [`MethodVerifier`](https://android.googlesource.com/platform/art/+/master/runtime/verifier/method_verifier.cc)
  model while retaining its permissive superclass-constructor behavior used by
  optimized DEX.
- Synthetic object fixtures now execute explicit constructors instead of
  relying on the interpreter's previous implicit initialized-reference state.
  Nine new regressions cover cross-family misuse, polymorphic constants,
  conversion outputs, alias initialization, premature constructor return,
  double initialization, and initialized/uninitialized joins.
- At that checkpoint MihonCompatKit passed 103 tests, including 68 interpreter
  tests and all eight pinned real-extension paths. The all-products debug build
  and the KamiCore dependency build/test also pass on Windows/Swift 6.3.3.

Commit `b079d69` subsequently completed resolved reference-hierarchy and
catch-type assignability. Remaining opcodes, broader external class resolution,
and differential AOSP fixtures remain issue #1 work.

## What the preceding register-category continuation completed

Commit `7ce3c81` adds bounded register-category verification and corrects the
interpreter's binary arithmetic opcode mapping:

- All structurally accepted instructions receive static register-bounds checks,
  even when unreachable. Exposed string, type, field, method, and prototype
  indexes are also checked before dataflow begins.
- Method parameters seed the final `ins_size` words from the exact prototype and
  receiver staticness. A bounded worklist propagates types over normal and
  exception edges, with deterministic switch/handler successor ordering.
- The lattice tracks undefined and conflicting values, the
  verifier-polymorphic zero, category-1 primitives, adjacent wide halves, and
  reference descriptors. Wide-pair halves are invalidated when clobbered.
- Moves, result/return forms, invokes, fields, arrays, branches, unary/binary
  operations, and literal operations require compatible categories before the
  interpreter runs. The per-method caps are 250,000 states, 8,000,000 register
  cells, and 8,000,000 merges.
- The new checks exposed a real semantic error in the interpreter's
  `0x90...0xcf` table. It now follows AOSP's operation/type-major ordering;
  BatCave's real `0x95` instruction executes as `and-int` instead of being
  misread as `sub-long` and silently coerced through defensive zero values.
- Eight focused register-verifier regressions and one binary-op ordering
  regression bring MihonCompatKit to 94 passing tests. All eight pinned
  real-extension paths still pass, and a clean KamiCore dependency build sees
  the new verifier source.

At that checkpoint, exact `int`/`float` and `long`/`double` distinctions,
uninitialized-instance constructor rules, resolved reference-hierarchy
assignability, and resolved catch-type assignability to `Throwable` remained.
Commit `10bf770` subsequently completed the primitive and constructor-state
portions; commit `b079d69` subsequently completed the resolved hierarchy and
catch-type portions.

## What the preceding exception-verifier continuation completed

Commit `66d4126` extends pre-execution verification through DEX exception data
and the related verifier-only control-flow rules:

- Exception-table decoding now throws on malformed data instead of silently
  treating the method as if it had no handlers. Verified, decoded `DexTryBlock`
  values are cached once per method and used directly during execution.
- The verifier requires zero try padding, nonempty and ordered non-overlapping
  try ranges on instruction boundaries, exact handler offsets, bounded 32-bit
  ULEB/SLEB encodings, valid catch type indexes/descriptors, and handler targets
  on executable instruction boundaries.
- Synthetic methods prove typed and catch-all handlers actually execute.
  Handler bodies may deliberately ignore the exception, matching current ART
  behavior rather than imposing an invalid `move-exception` requirement.
- AOSP verifier rules now reject zero-offset `goto`, `goto/16`, and conditional
  branches, invalid `move-result` placement or branch targets, invalid
  `move-exception` placement or ordinary control-flow entry, and insufficient
  `outs_size`. Zero-offset `goto/32` remains valid.
- Eleven focused regressions cover the new rules. All 85 MihonCompatKit tests,
  including all eight pinned real-extension paths, pass locally, and KamiCore
  still builds as a dependency.

At that checkpoint, strict exception-table geometry and decoding were complete,
while register-category dataflow and resolved catch-type assignability remained.
Commit `7ce3c81` subsequently added bounded category-level dataflow.

## What the preceding structural-verifier continuation completed

Commit `284b24d` adds a bounded, one-time structural verifier before a DEX
method can execute:

- It decodes the entire code item using the standard DEX instruction-width
  table and rejects invalid/reserved or truncated instructions, even on paths
  the interpreter would not take.
- Direct branches, ordinary fallthrough, and packed/sparse switch cases must
  land on exact executable instruction boundaries inside the code item.
- Packed-switch, sparse-switch, and array-data payloads must be aligned,
  complete, and referenced by the matching opcode family. Sparse keys must be
  strictly increasing and array-data widths must be 1, 2, 4, or 8 bytes.
- Code items are capped at 2,000,000 code units, and successful verification
  is cached once per method for the lifetime of an interpreter.
- Nine focused regressions cover valid packed-switch execution and malformed
  truncation, operand branches, payload case targets, fallthrough, alignment,
  family mismatches, sparse ordering, and array element widths. All 74 tests,
  including all eight pinned real-extension paths, pass locally.

This was structural geometry/control-flow verification, not a claim of a full
Dalvik verifier. Commit `66d4126` subsequently added strict exception-table and
handler validation.

## What the earlier request-model continuation completed

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

The two focused request tests and eight pinned real-extension tests are part
of the 63-test MihonCompatKit suite at that historical baseline. All three
workflows linked above passed for that exact implementation SHA.

## What the earlier runtime continuation completed

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
  BatCave's interpreted popular, paginated text-search, latest-updates, and core
  details paths through exact request construction, bounded async response
  delivery, production selectors, and exact compatibility-model conversion.
- Source-scoped, bounded OkHttp request/response/body/Okio values, async nested
  frame resumption, cancellation, typed transport/HTTP errors, the exact pinned
  BatCave POST assertion, and a deterministic no-live-network test transport.
- Bounded pre-execution verification of complete instruction geometry,
  try/catch tables, register operands, resolved catch classes, and exact
  primitive/constructor/reference register dataflow over normal and exception
  edges.
- Native MangaDex browsing through the existing `KamiSource` implementation.
- Simulator/device compilation and creation of a real unsigned IPA.

Not proven or implemented:

- An interpreted extension completing chapters and pages and exposing all
  operations through `KamiSource`.
- Broad Jsoup coverage beyond the measured subset, kotlinx serialization,
  persistent source preferences and cookies, rate limiting, the
  tachiyomix-to-`KamiSource` bridge, or WebView challenge handling. The current
  cookie jar is source-isolated but in memory.
- Full DEX opcode coverage or complete hierarchy behavior when class data leaves
  the parsed DEX and bounded host graph. Structural
  code-item/control-flow/exception-table verification, exact
  primitive/constructor/reference register verification, resolved `Throwable`
  catch validation, runtime cast/catch checks, receiver-directed virtual/class
  dispatch, maximally specific interface defaults, and lexical class/interface
  `invoke-super` across parsed DEX graphs are working. Equivalent resolution
  across incomplete external hierarchy data remains open.
- APK signer authentication and update identity binding.
- A signed installation on a physical iPhone or iPad.
- Production compatibility telemetry or a declared repository license.

Do not describe bounded response delivery as end-to-end extension support.

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

- Native repository index/APK downloads still need broader streaming and
  aggregate resource accounting. The extension compat transport now enforces
  its own response-body cap while delegate bytes arrive.
- External-list/APK URL scheme, redirect, and destination policy is broad.
- ZIP/DEX/string processing lacks a complete aggregate resource budget.
- External class relationships absent from both the APK and bounded host graph
  remain deliberately unresolved; wider runtime resolution is required for
  exact casts and narrower typed catches across that boundary.
- Receiver-directed virtual lookup, interface-default selection, and lexical
  class/interface `invoke-super` are exact within parsed DEX graphs; complete
  resolution across hierarchy data that leaves the parsed DEX remains open.
- Instruction counts do not price expensive StringBuilder copying or every
  allocation/host-collection operation cost.

Address these before treating arbitrary downloaded extensions as safe.

## Open work and issue tracker

| Priority | Issue | Purpose |
|---|---|---|
| P0 | [#1 Complete DEX opcode coverage and verifier semantics](https://github.com/taizaki69/Kami/issues/1) | Remaining external hierarchy and super/default resolution, opcode, and differential semantics work |
| P0 | [#2 Build the first end-to-end interpreted Mihon source](https://github.com/taizaki69/Kami/issues/2) | One real APK through search/popular, details, chapters, pages, and `KamiSource` |
| Security gate | [#3 Verify APK signing identity](https://github.com/taizaki69/Kami/issues/3) | Required before downloaded APK execution |
| Diagnostics | [#4 Add privacy-safe compatibility telemetry](https://github.com/taizaki69/Kami/issues/4) | Deterministic, redacted unresolved-surface reports |
| Distribution | [#5 Add the declared Apache-2.0 license](https://github.com/taizaki69/Kami/issues/5) | Requires owner confirmation before adding the license |

The rest of the product backlog is in `TODO.md`.

## Recommended next implementation sequence

1. Work only with the pinned local corpus while the signer gate is absent.
2. Preserve exact prototype/staticness dispatch and use `compat-audit methods`
   plus canonical unresolved diagnostics for every new bridge decision.
3. Continue issue #1 with broader external hierarchy and super/default
   resolution, remaining opcodes, and differential AOSP coverage. Code-item
   geometry, strict try/catch decoding and resolved `Throwable` validation,
   branch/move-result/move-exception rules, bounded exact
   primitive/constructor/reference dataflow, runtime casts/catches,
   receiver-directed virtual/interface-default lookup, lexical parsed-DEX
   `invoke-super`, and invoke word-count/kind checks are already in.
4. Add aggregate parser/runtime resource accounting and streaming or
   delegate-limited repository downloads.
5. Continue issue #2 after the now-passing popular, paginated text-search,
   latest-updates, and core details paths. Drive chapter parsing next and record
   its first exact unresolved signature before adding host surface.
6. Implement the chapter path in bounded slices: script extraction, JSON
   serialization, `SChapter`, date parsing, and `SMangaUpdate`. Pages then
   introduce JSON request/response models and `Page`. Keep every test
   deterministic and offline and retain the existing parser/selector limits.
7. Expose the interpreted source through the existing `KamiSource` contract
   only after exact popular/search, details, chapters, and pages tests pass.
8. Implement issue #3 before enabling execution of arbitrary repository
   downloads or updates.
9. Add issue #4 diagnostics as local, deterministic, redacted output so the
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
| Method resolution | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexMethodResolver.swift` |
| Register/invoke verifier | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexRegisterVerifier.swift` |
| Native capability boundary | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/HostBridge.swift` |
| Pure HTTP request values | `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPRequest.swift` |
| Source-scoped HTTP transport | `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPTransport.swift` |
| Request-model regressions | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/CompatHTTPRequestTests.swift` |
| Async VM/response regressions | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/AsyncInterpreterTests.swift` |
| HTML compatibility and limits | `Packages/MihonCompatKit/Sources/MihonCompatKit/HTML/CompatHTML.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/HTMLCompatibilityTests.swift` |
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
