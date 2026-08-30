# Extension Runtime — Measured Status and Staged Plan

**Last updated:** 2026-08-29

## Where we are

Kami has crossed from DEX analysis into controlled execution. The partial M1
interpreter runs synthetic conformance fixtures and progressively deeper paths
from six pinned execution-fixture APKs. Exact BatCave, Kawii Manga, MangaMelon,
and Baozi Manhua profiles now cross the app-facing `KamiSource` boundary end to
end under deterministic offline fixtures. A separate set of 15 current lib 1.6
APKs is locked for non-executing measurement only. This is not yet a complete verifier,
Java or Kotlin runtime, general tachiyomix source bridge, or arbitrary-extension
implementation.

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
the full signing identity and manifest, preflights the profile's exact source-ID
set before DEX construction, selects an exact measured profile, and
postvalidates every source ID returned by construction against that set and the
persisted admission. The current catalog contains exact BatCave 1.6.9, Kawii
Manga 1.6.1, MangaMelon 1.6.1, and Baozi Manhua 1.6.29 profiles; an
authenticated but unmeasured extension is stored securely and left disabled
rather than executed heuristically. `SourceRegistry` removal is package-owner
scoped, so disabling one downloaded package cannot remove another package's
source IDs.

The public raw-byte profile constructors are a deliberate built-in/test seam,
not a downloaded-app bypass. They still reverify the exact profile hash and
signer (as well as manifest/plan identity); downloaded execution requires the
persisted admission capability and `ExtensionSourceFactory`.

The corpus lock additionally contains 15 current lib 1.6 Keiyoushi APKs under
`Tests/corpus/measurement/`. Alongside the six execution fixtures and six AOSP
apksig conformance fixtures, this is 27 artifacts total, including 19 current
lib 1.6 artifacts (four execution plus 15 measurement). The measurement set is
behavior-stratified, not statistical. The earlier 16-artifact measurement run
occupied 1.24 MB (1,242,086 bytes) before Baozi moved into the execution role.
Its artifacts are parsed, signature-verified for parser conformance, and
statically audited only: membership never grants signer trust, admission,
installation, or execution.

`InterpretedExtensionPlanInspector` is now the reusable, non-executing discovery
step shared by those exact profiles and `compat-audit plan`. It parses bounded
manifest, ZIP, and DEX data and either produces a deterministic structural plan
or stable blockers. The current plan contract requires the extension feature,
valid package/version identity, lib 1.6, one declared source class, no source
factory, exactly one unambiguous `classes.dex`, no native `.so` entries, the
entry class in that DEX, and one concrete public stable-wrapper location on its
local superclass chain. It does not authenticate a signer, grant an admission
capability, execute DEX, infer private R8 workers, or prove that network/source
operations work. The exact runtime calls it only after hash/signature/manifest
authentication and exact-catalog selection; declared source IDs are still
validated before any constructed source is returned.

Measured real-APK behavior today:

- Akuma 1.4.10, MangaDex 1.4.212, BatCave 1.6.9, Kawii Manga 1.6.1,
  MangaMelon 1.6.1, and Baozi Manhua 1.6.29 entry constructors return
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
- Kawii Manga routes the stable public search/update wrappers from its
  R8-merged generated entry class and executes real popular, latest, search,
  combined details/chapters, and page-list methods. Deterministic fixtures prove
  every exact JSON GET, returned compatibility model, and the custom `x-app-key`
  header on all five requests. The reached surface includes bounded
  `HttpUrl.Builder` queries, nullable and boolean generated serialization,
  ordered `distinct`, character-delimiter substring defaults, nullable string
  equality, and Kotlin `Instant` epoch conversion.
- MangaMelon derives a static `Sort`/`Select` filter schema from its exact APK,
  validates app mutations against the immutable names/options/shape, and sends
  the original DEX filter instances through the stable wrapper. Its complete
  popular/latest/filtered-search/details/chapters/pages regression proves
  default-inclusive JSON encoding, bounded UTF-8/Okio/Base64 form data,
  structured coroutine lambdas, `Long` decoding, stable comparator sorting,
  string-valued chapter memo JSON, and ordered pages.
- Baozi Manhua 1.6.29 is admitted as the fourth exact profile. Its locked APK
  is identified by SHA-256
  `7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`, signer
  fingerprint
  `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, and
  declared source ID `5724751873601868259`. Deterministic fake-transport
  regressions execute popular, latest, text search, combined details/chapters,
  and pages. They also assert Baozi's exact static filter list (one header and
  four `Select` values), apply a valid non-default tag selection that changes
  the filtered request, reject mutated filter schemas before transport, assert
  its bounded scalar preference keys, and execute its DEX `imageRequest(Page)`
  rewrite from the fixture CDN host to the image host.
- These source-result paths are proven only with deterministic offline response
  fixtures. `PinnedInterpretedSource` maps them through the complete app-facing
  contract and the iOS reader resolves one source `ImageRequest` per page
  asynchronously. No test claims dynamic/network-backed filter lists, live-site
  availability, or production preference persistence. Baozi's scalar preference
  values can be injected into the exact profile, but the app UI/storage path is
  not wired. The pinned suite never performs live network I/O.

The measurement-only static audit analyzes the remaining 15 current lib 1.6
artifacts with zero errors. It finds 11 structural candidates and four
stable-wrapper blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC), plus 563
unique unregistered external method surfaces and zero unsupported opcodes. These
are prioritization results, not a compatibility rate and not runtime evidence;
the measurement APKs remain outside the exact profile catalog and are never
admitted or executed by this path.

The iOS Browse screen now consumes that filter contract directly. A generic,
transactional sheet renders every `SourceFilter` case, including nested groups;
text searches preserve the source's full filter shape, and Apply can
deliberately route a blank query through filtered search. A pure KamiCore
request router tests popular/latest/text/filter-only selection independently of
SwiftUI. Browse reset generations prevent superseded requests from appending
stale results, and failed next-page requests no longer advance the page counter.

## Architecture

```text
Extension APK                       (untrusted)
   ↓ install + signature trust      durable, capability-gated
content-addressed APK               persisted; re-authenticated on restore
   ↓ exact profile catalog          BatCave + Kawii + MangaMelon + Baozi; measurement APKs fail closed
   ↓ bounded ZIP/DEFLATE + CRC      working
AndroidManifest.xml (AXML)          working
classes*.dex                        validated structural parse
   ↓ structural plan inspector      deterministic candidate/blockers; no trust
   ↓ DexInterpreter                 partial M1; async frame resume works
   ↓ Java/Kotlin HostBridge         partial exact-signature M2 surface
   ↓ source-scoped HTTP transport   bounded async request/response slice works
   ↓ bounded HTML/JSON bridges      all four measured core source paths work
   ↓ tachiyomix API bridge          four exact pinned profiles work
KamiSource (Swift protocol)         native + admitted measured adapters work
   ↓ SourceRegistry / app / DB      restore, enable/disable, filtered Browse work
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
  are cached per interpreter and method. It accepts D8/R8's tightly bounded
  unreachable alignment NOP only when it immediately follows a terminal
  instruction, precedes a payload, and has no branch, switch, or handler entry.
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

- Full instruction and payload coverage for the current measurement set and
  future corpus expansion.
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
- Kotlin `Intrinsics`, `Result`, basic structured continuation/coroutine setup, lazy
  values, pairs, `isBlank`, trimming, Java-compatible UTF-8 form URL encoding,
  bounded regex find, bounded default `joinToString`, delimiter substring/split
  helpers (including character-delimiter last-occurrence defaults), nullable
  case-aware equality, ordered `distinct` with a comparison budget, bounded
  stable comparator sorting,
  prefix/suffix checks, close-finally behavior, and mutable reference boxes.
  The regex helper is bounded by pattern, input, capture-count, and aggregate
  output sizes, but not by worst-case match steps or time; bounded or
  demonstrably linear-time regex hardening remains deferred.
- Mihon filter/filter-list construction and state access, bounded app-facing
  filter conversion, exact-shape state reapplication, plus construction shims
  for `HttpSource` and `ParsedHttpSource` superclasses. Baozi's exact static
  schema is one header plus four `Select` filters; mutated names/options/shape
  are rejected before transport.
- A bounded scalar `SharedPreferences` surface (`getString`/`getBoolean`,
  package-scoped context) is injected only for Baozi. Accepted strings are
  `BAOZI_BANNER` and `CHAPTER_ORDER` with values `0`, `1`, or `2`; accepted
  booleans are `QUICK_PAGES` and `REMOVE_DUPLICATE_IMAGES`. The generic model
  caps values, key sizes, and string sizes. Production preference UI and
  persistence are not wired.
- The date-pattern object needed by the pinned BatCave constructor plus the
  measured `LocalDate`/system-zone/start-of-day/epoch-millisecond path used by
  chapter dates. This is an exact tested subset, not full `java.time` parity.
- Transport-neutral, bounded OkHttp URL/header/form/text-body/cache/request,
  client-builder, interceptor-list, and call values. `newCall` records a
  `CompatHTTPRequest`; `await` and `awaitSuccess` use only the bridge's
  explicitly injected async transport. The measured `HttpUrl.Builder`
  `newBuilder`/`addQueryParameter`/`build` slice percent-encodes query
  components under the final 8 KiB URL budget, and `HttpSource.getHeaders`
  executes a source's exact `headersBuilder` override.
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
  list/string serializers, nullable values, booleans, ordered composite encoding, and primitive/nested-
  object composite decoding. It invokes each extension DTO's real generated
  `serialize`/`deserialize` methods, supports string and Okio-buffered input,
  preserves generated optional/default and required-field behavior, and caps
  encoded/decoded bytes, nodes/depth/members/keys/strings, descriptors, and
  collections. The MangaMelon path additionally proves `encodeDefaults`, JSON
  `Long` values, and a bounded string-valued `JsonObject` memo subset. It is not
  a claim of full kotlinx serialization.
- The reached tachiyomix model slice constructs and mutates `SManga`, applies
  `setUrlWithoutDomain`, constructs `MangasPage`, `SChapter`, `SMangaUpdate`, and
  `Page`, and converts those results to public Swift compatibility models
  without silently dropping entries. Core manga-detail fields, chapter URL/
  name/number/date fields, and page indexes/image URLs are proven through the
  real APK. The host bridge caps `MangasPage` and page-list outputs at 2,048
  entries, `SMangaUpdate` at 20,000 chapters, and each `Page` URL/image URL at
  8 KiB. Metadata and source inputs have separate field limits; these are
  resource bounds, not a claim of unrestricted tachiyomix model fidelity.
- Kotlin duration encoding/conversion reached by OkHttp cache-control setup.
- Kotlin `Instant.parseOrNull` and exact epoch-millisecond conversion reached by
  Kawii chapter dates.
- UTF-8-only `String.getBytes`, immutable Okio `ByteString` slicing, and Base64
  encoding reached by MangaMelon's request envelope.
- Baozi's exact `imageRequest(Page)` method returns a bounded `ImageRequest`;
  the locked regression proves its CDN-host rewrite without network I/O. This
  is a profile-specific result, not general custom image-request compatibility.

Signer-authenticated admission, durable installation/selection, exact-byte
restoration, and capability-consuming source construction are now measured.
Stable public `KeiSource` wrapper routing now works whether a wrapper remains on
a local superclass or is vertically merged by R8 into the generated entry, and
the second, third, and fourth current extensions are proven end to end. Bounded
shared plan generation now replaces duplicated structural discovery, but it does not
expand admission. A privacy-safe diagnostics layer now records propagated typed
VM linkage/opcode failures by app-facing stage and provides a non-executing
static corpus audit of unregistered external invocations, unsupported opcodes,
and plan blockers. The static method list is deliberately a priority signal,
not runtime proof: virtual/interface dispatch may resolve through a different
receiver class. The broader current corpus is now locked and measured: all 15
remaining measurement APKs analyzed without errors, with 11 structural
candidates, four stable-wrapper blockers, 563 unique unregistered external
method surfaces, and zero unsupported opcodes. The next layer is first-gap
capture below extension catch handlers and regression-promotion tooling.
Dynamic/network-backed filter lists, production preference UI/persistence, and
source-defined interceptor execution also remain open. The longer tail remains
additional Jsoup DOM behavior, string/collection overloads, broader
serialization, and Android context/UI shims. A class appearing in the
analyzer's `implementedClasses` set is only a coarse prioritization signal; it
does not mean every method on that class is callable.

## M3 — tachiyomix source bridge

The target is a signature-aware bridge from `HttpSource`, `SManga`, `SChapter`,
`MangasPage`, filters, network helpers, and Jsoup helpers onto `KamiSource`.
The exact BatCave, Kawii Manga, MangaMelon, and Baozi Manhua profiles implement
their respective measured subsets with one actor per source owning its mutable
interpreter and source-scoped transport. The app can construct any of the four
profiles from a restored admission. Their shared structural plan is derived
from the authenticated APK instead of copied into each profile. The 15
measurement APKs remain non-executing. Automatic profile admission beyond the
exact catalog and the remaining APIs are still M3 work. Per-source network
clients must own rate limits, cookies, and redacted tracing. The first pinned
end-to-end adapter is tracked in
[GitHub issue #2](https://github.com/taizaki69/Kami/issues/2).

### Current profile-specific boundary

Baozi's scalar preferences and DEX `imageRequest(Page)` rewrite are measured
capabilities of that exact APK profile. The production app currently passes
default preferences because preference UI and persistence are not wired. The
current OkHttp model records client/interceptor values, but `await` sends the
transport request directly; it does not execute the source interceptor chain.
The reader image pipeline receives only the URL/headers projection, so it drops
DEX `Request` identity/tags. Baozi banner cropping, redirect-domain rewriting,
and missing-image behavior are therefore not executed or proven through reader
image loads. URLSession's internal redirect handling does not substitute for
those interceptor semantics.

Reader chapter retry is driven by a structured `.task(id: reloadID)`; changing
the reload identity restarts the cancellable chapter load. Reader dismissal
runs disappearance cleanup and increments the load generation, so stale page
lists or image-request resolutions cannot publish after teardown. Per-page
image retry currently reuses the resolved `ImageRequest`; regenerating and
revalidating that request, including expiry and credential-refresh semantics,
is explicitly deferred. The reader transport currently permits an initial
`http://` image URL for every source (`allowsInsecureHTTP` is enabled) while
rejecting HTTPS-to-HTTP redirects. It does not yet receive each source's
explicit insecure-image policy, so policy-compliant reader fetching is an
unresolved blocker rather than a current behavior claim.

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

The structural inspector is deliberately outside the trust decision. Its
public result omits filesystem paths, URLs, signer material, and source-returned
values; a plan only says that the bounded parser recognized a currently
supported shape. Unknown bytes cannot reach `ExtensionSourceFactory` or
`SourceRegistry` from that result.

Compatibility diagnostics are outside the trust decision too.
`InterpretedCompatibilityRecorder` accepts only typed unresolved class, exact
method signature, field, and unsupported-opcode VM errors; cancellations,
budgets, verifier text, HTTP/parser failures, and arbitrary error descriptions
are discarded. Its bounded deterministic report contains only sanitized
package/version, operation stage, and DEX API/opcode identity. The static
auditor executes no bytecode and embeds only a sanitized plan status rather
than the raw manifest/archive inspection. `compat-audit gaps` replaces input
filenames with artifact ordinals and emits generic per-artifact parse failures.
Neither path authenticates, admits, installs, or registers an extension.

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

`MihonCompatKit` currently has 207 passing tests locally on Windows/Swift 6.3.3.
The three new `CorpusLockTests` regressions cover separated corpus roles,
SHA/URL/fetcher and manifest/signature checks, and the deterministic static
measurement baseline. The suite also includes 6 focused signer regressions
explicitly exercising all six real Keiyoushi execution APKs—Akuma, MangaDex,
BatCave, Kawii Manga, MangaMelon, and Baozi Manhua—while the AOSP fixtures are
separate signature-conformance inputs. All six execution fixtures receive
coverage (legacy constructor coverage plus four exact current source paths,
including Baozi), along with 3 deterministic structural-plan regressions,
4 privacy-safe runtime/static diagnostics regressions, 7 focused
HTML/parser-limit regressions, Java URL-encoding and bounded Kotlin
string/collection-helper regressions, generated chapter/page JSON success/
failure paths, 4 focused async interpreter/transport regressions, 4 BatCave
adapter/tamper/concurrency/policy regressions, 8 Baozi profile regressions, and complete Kawii/MangaMelon profile
regressions, alongside the existing parser, bytecode verifier, request-model,
repository, and compression coverage. KamiCore currently passes 14/14 portable
Windows tests, including
exact Baozi factory admission; the historical pre-Baozi macOS CI run covered
all 23, including reader settings and image-pipeline boundaries, Browse feed/
search routing, SQLite signer persistence,
repository-key pinning, install/update and legacy confirmation, exact-byte
restore/factory rejection, enabled-state preservation, and downloaded registry
replacement/removal. That historical Swift CI job verified its then-locked
SHA-256 APK corpus before running it.

The exact implementation commit `e56bd9a` is historical CI evidence, not a
result for the current corpus expansion: it passed
[Swift CI 32683073872](https://github.com/taizaki69/Kami/actions/runs/32683073872),
[iOS Build 32683073885](https://github.com/taizaki69/Kami/actions/runs/32683073885),
and [IPA Package 32683073873](https://github.com/taizaki69/Kami/actions/runs/32683073873).
Those runs predate the current corpus expansion and 192-test checkout; they
remain the available CI evidence until a new commit is pushed and rerun. They
covered the then-189-test compatibility suite, optimized CLI build, 23 KamiCore
tests, Simulator/device compilation, and unsigned IPA artifact. The iOS build
log contains no warning lines after adding the complete iPad orientation set.

The compatibility matrix records the exact versions, hashes, and methods. New
runtime behavior is complete only when it has a focused regression test and,
where applicable, a pinned real-extension assertion.

## Known non-goals or likely incompatibilities

- Extensions that require bundled native `.so` execution.
- Broad Android UI framework behavior beyond a deliberate compatibility shim.
- Downloaded native machine code or JIT compilation on iOS.
- App Store distribution of the downloadable-bytecode runtime without a
  separate policy and review decision; the current target is sideloading.
