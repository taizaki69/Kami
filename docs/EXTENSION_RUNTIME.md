# Extension Runtime — Measured Status and Staged Plan

**Last updated:** 2026-08-23

## Where we are

Kami has crossed from DEX analysis into controlled execution. The partial M1
interpreter runs synthetic conformance fixtures and progressively deeper paths
from three pinned, current Mihon extension APKs. One exact BatCave profile now
crosses the app-facing `KamiSource` boundary end to end under deterministic
offline fixtures. This is not yet a complete verifier, Java or Kotlin runtime,
general tachiyomix source bridge, or arbitrary-extension implementation.

The signer-authenticated admission and app installation layers are now wired
end to end. Before any downloaded APK can become registry-eligible, Kami
verifies its APK v2/v3/v3.1 signature or conservative v1 fallback, signed
content digest, X.509 signer key, and any v3 proof-of-rotation chain. Kami then
matches the exact Mihon-format certificate fingerprint against selected-store
metadata or an explicit user decision and atomically persists the package,
version, APK hash/path, source IDs, signer history, trust origin, and enabled
state. Content-addressed APK storage, install/update controls, legacy-store
signer confirmation, enable/disable controls, and startup restoration all use
that same gate.

`ExtensionSourceFactory` is the only admission-capability consumer. It re-reads
the durable APK once into a bounded immutable buffer, rehashes it, re-verifies
the full signing identity and manifest, selects an exact measured profile, and
rejects any constructed source ID that the repository did not declare. The
current catalog contains one exact BatCave 1.6.9 profile; an authenticated but
unmeasured extension is stored securely and left disabled rather than executed
heuristically.

Measured real-APK behavior today:

- Akuma 1.4.10, MangaDex 1.4.212, and BatCave 1.6.9 entry constructors return
  real DEX objects.
- BatCave 1.6.9 returns its real base URL, language, name, and 64-bit source ID.
- BatCave's real `getPopularManga` path executes class initialization, Kotlin
  pairs and collections, Mihon filters and iteration, and coroutine setup. It
  builds its exact bounded POST form request, crosses a deterministic injected
  async transport, resumes nested real DEX frames, and receives bounded OkHttp
  response/body values. Its real parser then crosses
  `JsoupExtensionsKt.asJsoup$default(Response, String, int, Object)`, runs the
  production CSS selectors, resolves relative URLs, constructs `SManga` values,
  and returns an exact two-entry `MangasPage` with pagination.
- A separate pinned BatCave regression proves `awaitSuccess` maps a 503 response
  to Mihon's typed `HttpException` with the exact status code.
- BatCave's real nonblank text-search worker trims and Java-form-encodes a page-2
  query, builds the exact cached GET, and parses its result into `MangasPage`.
- BatCave's public latest-updates operation builds its cached page-3 GET and
  parses the production card selectors into a paginated `MangasPage`.
- Its real manga-details worker fetches an `HttpUrl` and returns URL, title,
  thumbnail, publisher/year description, author, artist, genres, and status.
  This crosses modern Jsoup direct-child `:has(> ...)` and element-relative
  `> ...` selectors plus Kotlin's default collection join behavior.
- Its real combined manga-update worker reuses that cached GET, locates
  `script:containsData(window.__DATA__)`, extracts the bounded payload, and
  drives the APK's generated kotlinx serializers through a bounded generic JSON
  decoder. It returns multiple exact `SChapter` values and `SMangaUpdate`, with
  xhash URLs, fractional numbers, source-local epoch dates, and Mihon's zero
  fallback for an invalid date. Malformed JSON and missing required fields
  surface as typed serialization failures.
- Its real page-list worker splits the chapter URL, runs the APK's generated
  request serializer, sends the exact JSON POST, decodes
  `ChapterApiResponse.data.images` from `okio.BufferedSource` through the
  generated response serializers, normalizes relative and absolute image URLs,
  and returns exact public `PageCompat` values. Malformed JSON, invalid UTF-8,
  and a wrong images type surface as typed serialization failures.
- These source-result paths are proven only with deterministic offline response
  fixtures. `PinnedInterpretedSource` maps them through the complete app-facing
  contract and proves a default reader image request, but no test claims
  filtered search, the optional related-manga JSON memo, preferences,
  Cloudflare behavior, custom image-request overrides, or live-site
  availability. The pinned suite never performs live network I/O.

## Architecture

```text
Extension APK                       (untrusted)
   ↓ install + signature trust      durable, capability-gated
content-addressed APK               persisted; re-authenticated on restore
   ↓ exact profile catalog          BatCave 1.6.9 measured; others fail closed
   ↓ bounded ZIP/DEFLATE + CRC      working
AndroidManifest.xml (AXML)          working
classes*.dex                        validated structural parse
   ↓ DexInterpreter                 partial M1; async frame resume works
   ↓ Java/Kotlin HostBridge         partial exact-signature M2 surface
   ↓ source-scoped HTTP transport   bounded async request/response slice works
   ↓ bounded HTML/JSON bridges      BatCave browse/details/chapters/pages works
   ↓ tachiyomix API bridge          pinned BatCave profile works
KamiSource (Swift protocol)         native + admitted BatCave adapter work
   ↓ SourceRegistry / app / DB      restore, enable/disable, Browse work
```

The interpreter consumes `DexFile` code items directly. It follows the Android
DEX instruction formats and bytecode semantics documented by AOSP:

- https://source.android.com/docs/core/runtime/instruction-formats
- https://source.android.com/docs/core/runtime/dalvik-bytecode
- https://source.android.com/docs/core/runtime/dex-format

## M1 — Interpreter core

Implemented slice:

- Incoming parameters occupy the final `ins_size` register words, including
  wide values; calls and entry-triggered class initializers use one shared
  instruction budget across the call tree.
- Integer, long, float, double, object, null, array, and host values; instance
  and static fields; object and array allocation.
- Move/constant/return, branches and switches, arrays, fields, invoke and
  invoke-range, conversions, comparisons, arithmetic, literal, and two-address
  opcode families reached by the current fixtures.
- Before a method first executes, a 2,000,000-code-unit-capped structural
  verifier decodes its complete instruction stream. It rejects invalid or
  truncated opcodes, branches/fallthrough/switch cases that do not land on
  instruction boundaries, misaligned/truncated/mismatched payloads, invalid
  array element widths, and unsorted sparse-switch keys. Successful results
  are cached per interpreter and method.
- The same pass strictly decodes and caches `try_item` and encoded catch-handler
  data. It validates zero padding, ordered non-overlapping instruction ranges,
  exact handler offsets, bounded SLEB32/ULEB32 values, catch types and targets,
  and AOSP control-flow rules for `move-result`, `move-exception`, branch-zero
  forms, and `outs_size`. Resolved catch classes must derive from `Throwable`;
  unresolved external catch classes retain verifier soft-failure behavior.
  Typed and catch-all handlers execute, and handlers may intentionally ignore
  the exception as ART permits.
- Every structurally accepted instruction has its register and exposed
  string/type/field/method/prototype operands checked, including unreachable
  code. A bounded worklist then propagates seeded parameter types across normal
  and exception edges. Its ART-shaped lattice tracks bounded polymorphic
  constants; boolean, byte, char, short, int, and float registers; distinct
  long/double pairs; initialized references; allocation-site-specific
  uninitialized references; uninitialized constructor `this`; undefined
  values; and conflicts. Constructor calls initialize every alias, ordinary
  reference use rejects uninitialized objects, and constructors cannot return
  before initializing `this`. Resolved references join at their common
  superclass (including covariant reference arrays), and assignments for
  returns, calls, fields, arrays, constructors, and throws reject known
  unrelated types. `move-exception` receives the common resolved catch type.
  The pass also checks moves/results, branches, conversions, and numeric
  operations before execution. The caps are 250,000 states, 8,000,000 register
  cells, and 8,000,000 merges per method.
- Java-compatible integer divide/remainder edge cases, reference identity,
  hierarchy-aware `check-cast`, `instance-of`, and typed exception dispatch,
  `throw null` behavior, recursion limit, cancellation, and trace callback.
- Public async entry calls capture every suspended interpreted frame and resume
  nested call chains inside-out after an exact async host method completes.
  Shared instruction budgets, typed DEX catch handling at the original invoke,
  repeated suspension, and Swift Task cancellation are preserved.
- Exact name/prototype dispatch for interpreted and host calls. Virtual calls
  walk the runtime receiver's parsed class chain; interface calls prefer class
  declarations and then apply maximally specific default-method selection,
  including abstract masking and conflict detection. Class `invoke-super`
  starts at the lexical caller's direct superclass, and DEX 037+ interface
  `invoke-super` searches only the referenced interface graph. Static/instance
  and class/interface invoke kinds, local method-list placement, DEX version,
  lexical supertype relationships, invoke word count, caller `outs_size`,
  wide-register pairing, logical argument categories, and return categories
  are checked. Missing, abstract, and conflicting resolved dispatches surface
  as typed `NoSuchMethodError`, `AbstractMethodError`, and
  `IncompatibleClassChangeError`; incomplete external graphs stay unresolved.
- One-time DEX class initialization, including DEX superclass initialization,
  before static use and allocation; failed initialization remains failed.
- Precise unresolved-class/method/opcode failures instead of treating arbitrary
  VM errors as compatibility success. Trace entries include depth and canonical
  method identity.
- Binary operations `0x90...0xcf` follow the AOSP operation/type grouping for
  int, long, float, double, and `/2addr`; the pinned BatCave path now executes
  its real `0x95` `and-int` instead of relying on a defensive zero coercion.

Still required before M1 is complete:

- Full instruction and payload coverage for the expanding corpus.
- Complete interface-default and invoke-super resolution when hierarchy data
  leaves the parsed DEX.
- Broader resolution for external Java/Kotlin/Android class graphs that are not
  defined in the APK or the bounded host hierarchy.
- Differential fixtures against AOSP-compatible reference execution.

This work is tracked in [GitHub issue #1](https://github.com/taizaki69/Kami/issues/1).

## M2 — Java/Kotlin and Android-compatible host surface

The current exact-signature allow-list covers only behavior reached by the
synthetic and pinned-corpus tests:

- `java.lang.Object`, `String`, and `StringBuilder` basics.
- Confined Java reflection over DEX fields and the source-base field bag;
  primitive boxes, atomics, concurrent maps, bounded lists, and iterators.
- Kotlin `Intrinsics`, `Result`, basic synchronous continuation setup, lazy
  values, pairs, `isBlank`, trimming, Java-compatible UTF-8 form URL encoding,
  bounded regex find, bounded default `joinToString`, delimiter substring/split
  helpers, prefix/suffix checks, close-finally behavior, and mutable reference
  boxes.
- Mihon filter/filter-list construction and state access, plus construction
  shims for `HttpSource` and `ParsedHttpSource` superclasses.
- The date-pattern object needed by the pinned BatCave constructor plus the
  measured `LocalDate`/system-zone/start-of-day/epoch-millisecond path used by
  chapter dates. This is an exact tested subset, not full `java.time` parity.
- Transport-neutral, bounded OkHttp URL/header/form/text-body/cache/request,
  client-builder, interceptor-list, and call values. `newCall` records a
  `CompatHTTPRequest`; `await` and `awaitSuccess` use only the bridge's
  explicitly injected async transport.
- A per-source URLSession transport enforces request/response limits, redirect
  policy, timeouts, cancellation, streaming response-body limits, and an
  isolated in-memory cookie jar. Tests use an actor-backed fake transport.
- Bounded `Response`, `ResponseBody`, `Headers`, and `okio.BufferedSource`
  models cover status/header access, common charsets, one-shot bytes/text reads,
  close state, and Mihon's non-2xx `HttpException` behavior.
- SwiftSoup 2.9.6 supplies HTML5 parsing and CSS semantics behind an exact
  Jsoup-compatible document/element/elements slice. Kami caps input bytes, DOM
  nodes/depth/attributes, selector length/results/cumulative work, and extracted
  strings before values return to DEX. A bounded adapter supplies the modern
  direct-child relative selectors and `:containsData(...)` semantics reached by
  the details/chapter parsers even though the pinned SwiftSoup release predates
  those Jsoup behaviors.
- A bounded JSON encode/decode subset supplies generated serial descriptors,
  list/string serializers, ordered composite encoding, and primitive/nested-
  object composite decoding. It invokes each extension DTO's real generated
  `serialize`/`deserialize` methods, supports string and Okio-buffered input,
  preserves generated optional/default and required-field behavior, and caps
  encoded/decoded bytes, nodes/depth/members/keys/strings, descriptors, and
  collections. It is not a claim of full kotlinx serialization.
- The reached tachiyomix model slice constructs and mutates `SManga`, applies
  `setUrlWithoutDomain`, constructs `MangasPage`, `SChapter`, `SMangaUpdate`, and
  `Page`, and converts those results to public Swift compatibility models
  without silently dropping entries. Core manga-detail fields, chapter URL/
  name/number/date fields, and page indexes/image URLs are proven through the
  real APK.
- Kotlin duration encoding/conversion reached by OkHttp cache-control setup.

Signer-authenticated admission, durable installation/selection, exact-byte
restoration, and capability-consuming source construction are now measured.
The next layer is general profile discovery: replace the exact profile's
R8-private worker mapping with a measured inherited `KeiSource`/`HttpSource`
wrapper path and prove a second current extension end to end. Filtered search
and a real custom image-request override follow. The longer tail remains
additional Jsoup DOM behavior, string/collection overloads, broader
serialization, preferences, and Android context/UI shims. A class appearing in
the analyzer's
`implementedClasses` set is only a coarse prioritization signal; it does not
mean every method on that class is callable.

## M3 — tachiyomix source bridge

The target is a signature-aware bridge from `HttpSource`, `SManga`, `SChapter`,
`MangasPage`, filters, network helpers, and Jsoup helpers onto `KamiSource`.
The exact BatCave profile implements the currently measured subset with one
actor owning its mutable interpreter and source-scoped transport. The app can
construct that profile from a restored admission, but general profile discovery
and the remaining APIs are still M3 work. Per-source network clients must own
rate limits, cookies, and redacted tracing. The first pinned end-to-end adapter
is tracked in
[GitHub issue #2](https://github.com/taizaki69/Kami/issues/2).

## M4 — WebView/Cloudflare bridge

Use a `WKWebView` session only for user-solved challenges, then synchronize its
cookies and User-Agent back into the source's native network session. There is
no claim of bypassing challenges.

## Untrusted-input boundary

The current parsers reject malformed table ranges, non-progressing chunks,
overlong LEB128 values, excessive field/entry counts, encrypted or multi-disk
ZIPs, oversized entries, decompression bombs, invalid DEX versions, and failed
ZIP/DEX/zlib/gzip checksums. Interpreter execution has instruction, call-depth,
array-size, host-collection-size, and cancellation limits. Native host calls
  require an exact method prototype and static/instance kind. Response HTML is
  bounded before parsing, and its DOM shape, attributes, selector inputs/results,
  cumulative selector work, and extracted strings have independent limits.
  Extracted JSON is byte-capped before parsing and independently bounded by
  decoded nodes, depth, members, key/string size, and collection capacity.

Checksums establish corruption detection, not publisher identity. The completed
signer gate verifies v1/v2/v3 signatures and APK content digests, normalizes
certificate identities exactly as Mihon does, verifies v3 rotation lineage, and
rejects unsigned, tampered, wrong-signer, stripped-scheme, downgraded, or
same-version-replaced APKs. Initial repository or explicit-user trust is sticky
and persisted before the only downloaded-source registry path can be called.
[GitHub issue #3](https://github.com/taizaki69/Kami/issues/3) records the
implementation and exact-head evidence. The shipping app now has a durable
installation/selection flow and an exact-profile downloaded-APK source factory.
The factory refuses authenticated extensions outside its measured catalog, so
this completed trust path still does not claim arbitrary extension
compatibility.

## Verification

`MihonCompatKit` currently has 171 passing tests locally on Windows/Swift 6.3.3.
They include 6 focused signer regressions, 17 pinned real-extension executions,
7 focused HTML/parser-limit regressions, Java URL-encoding and bounded Kotlin
string/collection-helper
regressions, generated chapter/page JSON success/failure paths, and 4 focused
async interpreter/transport regressions, plus 3 end-to-end adapter/tamper/
concurrency regressions, alongside the existing parser, bytecode verifier,
request-model, repository, and compression coverage. KamiCore has 7 portable
Windows tests; macOS CI runs all 18, including SQLite signer persistence,
repository-key pinning, install/update and legacy confirmation, exact-byte
restore/factory rejection, enabled-state preservation, and downloaded registry
replacement/removal. Swift CI verifies the SHA-256-locked APK corpus before
running it.

Exact implementation commit `4d42def` passes
[Swift CI 32668016125](https://github.com/taizaki69/Kami/actions/runs/32668016125),
[iOS Build 32668016122](https://github.com/taizaki69/Kami/actions/runs/32668016122),
and [IPA Package 32668016110](https://github.com/taizaki69/Kami/actions/runs/32668016110).
Those runs cover the 171-test compatibility suite, optimized CLI build, 18
KamiCore tests, Simulator/device compilation, and unsigned IPA artifact.

The compatibility matrix records the exact versions, hashes, and methods. New
runtime behavior is complete only when it has a focused regression test and,
where applicable, a pinned real-extension assertion.

## Known non-goals or likely incompatibilities

- Extensions that require bundled native `.so` execution.
- Broad Android UI framework behavior beyond a deliberate compatibility shim.
- Downloaded native machine code or JIT compilation on iOS.
- App Store distribution of the downloadable-bytecode runtime without a
  separate policy and review decision; the current target is sideloading.
