# Extension Compatibility Matrix

**Last updated:** 2026-08-29

**Corpus:** Keiyoushi release assets vendored from recorded release URLs and
pinned by SHA-256 via `scripts/fetch_corpus.sh`, then verified against
`Tests/corpus/manifest.json`. The URLs remain provenance and best-effort
fallback attempts only while reachable and only when recovered bytes match the
exact lock; `git restore Tests/corpus` is the durable recovery path.

This matrix separates structural loading, shallow VM execution, and full source
operations. A check mark means a concrete assertion passed; a dash means there
is no compatibility claim.

## Pipeline status

| Stage | Status | Evidence |
|---|---|---|
| Store index (`index.pb` + gzip) | Working | Live 2026-08-21 sample parsed 1,372 extensions, store metadata, external-list indirection, and signing-key metadata |
| Legacy JSON index | Working | Schema fixture decoded by `RepositoryIndexTests` |
| APK acquisition and durable install | Working | Repository entries download into content-addressed app storage; first trust uses the pinned repository key or explicit confirmation of an already-verified legacy-store signer; install/update and enable/disable state persist |
| APK signing identity | Working on locked v1/v2/v3 corpus | RSA PKCS#1/PSS and ECDSA signer signatures, AOSP chunked content digests, certificate/SPKI matching, v3 proof-of-rotation, stripping protection, exact Mihon SHA-256 fingerprints, and unsigned/tamper rejection are asserted before admission for executable artifacts; measurement signatures are verified for parser conformance only and never grant trust or admission |
| ZIP + DEFLATE | Working | STORE/DEFLATE real APK entries parse with size limits, exact decoded size, and CRC-32 verification |
| Binary Android manifest | Working | Package, entry class, flags, and string/float `extensionLib` values extracted from real APKs |
| DEX structural parse | Working on 21 locked real-extension APKs | Real corpus DEX files pass header/table/index/range checks plus Adler-32; the parser accepts the shared 035 and 037–040 header contract and rejects the different 041 container format |
| Structural execution-plan inspection | Working for the bounded single-source lib 1.6 shape | Non-executing inspection deterministically finds the entry and stable public wrapper for the four execution profiles and 11 of 15 remaining measurement APKs; the four measurement blockers are Komga, MangaPlus, NHentai.xxx, and XCOMIC. Legacy lib 1.4, factories, multidex, native `.so`, ambiguous/missing DEX, invalid identity, and missing wrapper shapes are explicit blockers. A plan establishes no signer trust, catalog admission, or execution proof |
| External-reference audit | Working heuristic | Cross-DEX definitions are reconciled before missing-class classification; class coverage is a priority signal, not method-level runtime proof |
| Static measurement corpus | Working, non-executing | Fifteen current lib 1.6 measurement-only APKs under `Tests/corpus/measurement/` are SHA/URL locked and analyzed 15/15 with 0 errors; 11 are structural candidates and four have stable-wrapper blockers (Komga, MangaPlus, NHentai.xxx, XCOMIC). The report contains 540 unique unregistered external method surfaces and 0 unsupported opcodes. The behavior-stratified set is prioritization evidence, not a statistical sample or execution/admission proof |
| Compatibility diagnostics | Partial, privacy-safe local/runtime and static corpus seams working | Pinned sources deduplicate propagated typed VM gaps by operation stage and ignore arbitrary errors; `compat-audit gaps` non-executingly ranks unregistered external method invocations, unsupported opcodes, and plan blockers with artifact ordinals rather than paths. The current measurement run reports 15/15 analyzed, 0 errors, 540 unique surfaces, and 0 unsupported opcodes. Static invocations are prioritization only, not runtime failure or admission proof. App export UI, below-catch first-gap capture, broader field/bridge instrumentation, and regression promotion remain open |
| DEX execution | Partial M1/M2 working | The current local 214-test suite includes exact source/execution paths against six execution fixtures; verified dispatch/dataflow semantics plus async nested-frame suspension, cancellation, typed handler re-entry, stable public-wrapper routing, bounded source-operation interceptor execution, bounded HTML/CSS, generated-serializer JSON encode/decode, filter-state round trips, page construction, scalar preferences, interpreted image requests, and serialized adapter ownership are checked |
| Admission restoration and source factory | Working for exact measured profiles | Startup re-reads the enabled installed APK, rechecks hash/signature/signer history/user trust/manifest, and gives the sole factory a fresh capability; before DEX construction the factory preflights the exact profile source-ID set, then postvalidates every constructed ID against that set and the admission, rejects undeclared IDs, and refuses unmeasured profiles; registry removal is scoped to the recorded package owner |
| End-to-end source operations | Working for four exact profiles | BatCave 1.6.9, Kawii Manga 1.6.1, MangaMelon 1.6.1, and Baozi Manhua 1.6.29 expose metadata, popular/latest/search, details, chapters, and pages through `KamiSource`; MangaMelon and Baozi add exact static `Select` filter paths. Source-operation `await`/`awaitSuccess` execute a bounded application/network interceptor chain, and Baozi's core regressions traverse its finite rate limiter. Baozi additionally proves bounded scalar preferences and an interpreted `imageRequest` rewrite. BatCave additionally proves the installed-source registry path. The 15 measurement APKs remain outside the executable catalog. Automatic catalog expansion, dynamic filters, production preference UI/persistence, reader-image interceptor execution, and live-site availability remain open |

## Per-extension execution

| Extension | Version | SHA-256 | Structural plan | Loads | Constructor | Metadata methods | Popular | Search | Details | Chapters | Pages |
|---|---:|---|---|:---:|:---:|---|---|:---:|:---:|:---:|:---:|
| MangaDex (`all.mangadex`) | 1.4.212 | `543dcf6a…306fa3` | blocked: lib 1.4 | ✅ | ✅ | — | — | — | — | — | — |
| Akuma (`all.akuma`) | 1.4.10 | `9f5e744e…ba39a` | blocked: lib 1.4 | ✅ | ✅ | — | — | — | — | — | — |
| BatCave (`en.batcave`) | 1.6.9 | `f5338a90…34fab6` | candidate | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ paginated text query | ✅ core fields | ✅ combined update | ✅ exact JSON POST + URLs |
| Kawii Manga (`ar.kawiimanga`) | 1.6.1 | `9e6110b8…dd52a` | candidate | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ text query | ✅ core fields | ✅ combined update | ✅ exact JSON GET + URLs |
| MangaMelon (`en.mangamelon`) | 1.6.1 | `aedbd5ba…0d9aa` | candidate | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ text + `Sort`/`Select` filters | ✅ core fields | ✅ combined update + memo | ✅ exact Base64 form POST + ordered URLs |
| Baozi Manhua (`zh.baozimanhua`) | 1.6.29 | `7e8c99fb…79cbec` | candidate | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ text + exact static filters | ✅ core fields | ✅ combined update | ✅ exact HTML image URLs + interpreted image request |

“Candidate” in this table is intentionally weaker than every execution column.
For the four exact rows it means bounded inspection found the supported lib 1.6
single-source structure before the independent hash/signer/admission checks;
the execution columns are backed by deterministic real-APK regressions. The
legacy constructors below remain useful shallow VM fixtures, but the plan
builder does not pretend their lib 1.4 API shape is the current stable-wrapper
contract.

## Measurement-only current lib 1.6 corpus

The lock has 15 SHA/URL-locked current lib 1.6 Keiyoushi APKs under
`Tests/corpus/measurement/`. They are separate from the six execution fixtures
(four current lib 1.6 and two legacy lib 1.4) and six AOSP apksig conformance
fixtures: 27 artifacts total, including 19 current lib 1.6 artifacts. This is a
behavior-stratified, not statistical, selection covering distinct extension
families and shapes.

The measurement APKs are parsed, signature-verified for parser conformance, and
statically audited only. Membership never grants signer trust, admission,
installation, or execution. The deterministic `compat-audit gaps
Tests/corpus/measurement` baseline analyzed 15/15 artifacts with 0 errors,
found 11 structural candidates and four stable-wrapper blockers (Komga,
MangaPlus, NHentai.xxx, and XCOMIC), and reported 540 unique unregistered
external method surfaces with 0 unsupported opcodes. These results are
prioritization signals, not a compatibility percentage or runtime proof.

The 11 remaining structural candidates are Doctruyen3q, EternalMangas,
FoolSlide Customizable, Hayalistic, Komikcast, MangaPandaOnl, Mangas Origines
FR, PixivComic, ReadManga, SSSCanlator, and TuttoAnimeManga. Baozi Manhua
1.6.29 is no longer in this measurement role: it is the fourth exact execution
profile, independently authenticated and tested below.

## Exact execution-profile evidence

All six constructors execute their real no-argument DEX paths and return
objects of the declared entry type. BatCave's popular path additionally proves
class initialization, filter construction and iteration, its Kotlin ABI, and
bounded OkHttp request construction. It asserts the exact POST URL and ordered
form fields, crosses a deterministic source-scoped transport, resumes nested
DEX frames, and receives a bounded response. It then crosses the exact
`JsoupExtensionsKt.asJsoup$default` call and parses the source's real selectors,
relative links, thumbnails, and pagination into two exact
`SManga` values and a `MangasPage`. The response fixture is offline; this does
not claim live-site availability or arbitrary-extension compatibility. The pinned
text-search worker additionally proves whitespace trimming, Java-compatible
UTF-8 form encoding, GET construction, page routing, source cache policy, and
the no-next-page result. BatCave-specific filtered search is not claimed.

The public latest-updates path proves its cached page-3 GET and pagination.
The real details worker proves URL, title, thumbnail, publisher/year
description, author, artist, genres, and status. Its optional related-manga JSON
memo branch is deliberately not claimed yet.

The real combined manga-update worker proves the cached detail GET, Jsoup
`script:containsData(...)`, bounded script extraction, the APK's generated
`Chapters`/`Chapter` deserializers, nested lists, required/default fields,
`SChapter` construction, xhash URLs, fractional chapter numbers, local-zone
dates, invalid-date fallback, and `SMangaUpdate`. Malformed JSON and a missing
required field are rejected as typed serialization failures.

The real page-list worker proves chapter-URL splitting, numeric chapter-ID
extraction, the APK's generated request serializer, the exact JSON POST,
Okio-backed generated response decoding, relative/absolute URL normalization,
and Tachiyomi `Page` conversion. Malformed JSON, invalid UTF-8, and a wrong
images type are rejected as typed serialization failures.

Kawii Manga proves the stable public wrapper route on a current lib 1.6 source
whose wrappers were vertically merged by R8 into the generated entry class.
Its locked APK executes popular, latest, dynamic text search, combined details
and chapters, and page-list operations against deterministic JSON fixtures. The
test asserts every exact GET URL and that the source's `x-app-key` header reaches
all five requests. This path also proves bounded `HttpUrl.Builder` query
encoding, nullable and boolean generated serialization, Kotlin nullable string
equality, ordered `distinct`, character-delimiter substring defaults, Kotlin
`Instant.parseOrNull`/epoch milliseconds, and the R8 payload-alignment NOP
accepted only when unreachable after a terminal instruction.

MangaMelon proves the first exact filter-state round trip. The authenticated
APK constructs a bounded static `FilterList`; Kami converts its `Sort` and
`Select` options to app-facing values, rejects any changed name/options/shape
before transport, mutates only validated state on the original DEX instances,
and observes the source's selected `rating`/`Comedy` values in the exact
request. Popular, latest, and filtered search encode every default DTO field,
then take the measured UTF-8 → Okio `ByteString` → Base64 form path. Combined
details/chapters and pages additionally exercise structured coroutine lambdas,
JSON `Long` values, stable comparator sorting, string-valued chapter memo JSON,
Kotlin `Instant`, and deterministic page ordering. All responses are offline
fixtures; dynamic/network-backed filter lists remain unclaimed.

Baozi Manhua 1.6.29 is the fourth exact execution profile. Admission checks its
package/version (`eu.kanade.tachiyomi.extension.zh.baozimanhua`, 1.6.29/code
29), SHA-256
`7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`, signer
fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, manifest,
and source ID `5724751873601868259`. Its fake-transport regression executes
popular, latest, text search, combined details/chapters, and pages from the
unmodified DEX. The exact filter result is one header plus four static
`Select` filters (`标签`, `地区`, `进度`, `标题开头`), all with validated options
and default state. A valid non-default tag selection is also applied and is
observed as a distinct filtered request; a mutated filter schema is rejected
before transport. The bounded preference surface accepts the two scalar string
keys `BAOZI_BANNER` and `CHAPTER_ORDER` (values `0`, `1`, or `2`) and the two
boolean keys `QUICK_PAGES` and `REMOVE_DUPLICATE_IMAGES`. The same regression
executes `imageRequest(Page)` and proves the fixture CDN-host rewrite without
network I/O.

`PinnedInterpretedSource` accepts only the locked BatCave, Kawii, MangaMelon, or
Baozi bytes after exact SHA-256, APK signer fingerprint, manifest
package/lib/entry-class, and shared structural-plan checks. For downloaded
execution, `ExtensionAdmissionService.restore` first re-authenticates the
enabled durable installation and `ExtensionSourceFactory` rechecks the exact
immutable bytes, preflights the profile's exact source-ID set before DEX
construction, and postvalidates the constructed IDs against that set and
admission before selecting this profile. The public raw-byte constructors are a
deliberate built-in/test seam: they still reverify the exact profile hash and
signer, while downloaded execution requires persisted admission and this
factory. It owns one
source-scoped interpreter and transport behind a bounded cancellation-aware
queue, maps every operation above into `KamiSource`, reuses the combined update
for one-request library refreshes, validates default HTTP(S) page image
requests, and registers in KamiCore without source-kind branches. The four
profile suites prove their respective deterministic contracts; Baozi additionally
proves preference admission, exact filter-schema rejection before transport,
and interpreted image-request conversion.

The source-model host bridge bounds app-facing outputs before conversion:
`MangasPage` and page-list collections are capped at 2,048 entries,
`SMangaUpdate` at 20,000 chapters, and each `Page` URL/image URL at 8 KiB.
Metadata and source inputs have separate field bounds; these limits are
resource hardening, not full tachiyomix model fidelity.

## Current measured API workload

The current `compat-audit gaps Tests/corpus/measurement` baseline is the
authoritative workload snapshot for the 15 current lib 1.6 measurement APKs.
It analyzes every artifact without executing DEX, reconciles classes defined
across the APK's DEX entries, compares exact external method
prototypes/staticness with the current host registry, and ranks each surface by
extension and invocation count:

| Measurement result | Count |
|---|---:|
| Artifacts analyzed | 15/15 |
| Artifact analysis errors | 0 |
| Structural candidates | 11 |
| Stable-wrapper blockers | 4 |
| Unique unregistered external method surfaces | 540 |
| Unsupported opcodes | 0 |

The four stable-wrapper blockers are Komga, MangaPlus, NHentai.xxx, and XCOMIC.
The 540-surface list is a prioritization signal, not a compatibility rate:
virtual/interface dispatch may resolve through a different receiver class, and
dead code may never execute. The measurement artifacts are not admitted or
executed, and their membership does not establish signer trust.

Two optimized Windows runs exited 0 and produced byte-identical UTF-8 reports
(98,876 bytes; SHA-256
`37503437e4b0aa67bf17fe13fa0b1d1b1d5ab05d5d2583964b2de0c0fcfd99e3`). The
reports contain no local-path, corpus-path, APK-filename, URL, authorization or
proxy-authorization header, `Set-Cookie`, `Bearer`, `token=`, or `password=`
markers. Safe DEX API identities such as `okhttp3/Cookie` and `CookieJar` are
not redaction failures.

The older class-only workload snapshot from the original execution fixtures is
no longer the corpus aggregate; use the locked baseline and deterministic gaps
report above for current prioritization.

## Test evidence

- 214/214 MihonCompatKit tests pass locally on Windows/Swift 6.3.3 with the
  corpus present. Three new `CorpusLockTests` cover separated roles,
  SHA/URL/fetcher and manifest/signature checks, and the deterministic static
  measurement baseline.
- The current portable Windows KamiCore suite passes 14/14 tests, including
  exact Baozi factory admission. Exact interceptor head `0ccb518` passes all
  25 KamiCore tests on macOS.
- Exact interceptor implementation head `0ccb518` passes
  [Swift CI 33286986621](https://github.com/taizaki69/Kami/actions/runs/33286986621),
  [iOS Build 33286986601](https://github.com/taizaki69/Kami/actions/runs/33286986601),
  and [IPA Package 33286986710](https://github.com/taizaki69/Kami/actions/runs/33286986710).
  Swift CI found all 27 fixtures already hash-matched, passed 214/214
  MihonCompatKit tests and 25/25 KamiCore tests, built the optimized CLI, and
  uploaded it. The iOS and IPA runs passed both build destinations and unsigned
  packaging respectively.
- Historical exact corpus head `a376064` passes
  [Swift CI 33279595763](https://github.com/taizaki69/Kami/actions/runs/33279595763),
  [iOS Build 33279595816](https://github.com/taizaki69/Kami/actions/runs/33279595816),
  and [IPA Package 33279595746](https://github.com/taizaki69/Kami/actions/runs/33279595746).
  Its Swift CI found all 27 fixtures already hash-matched, passed 3/3 corpus tests,
  192/192 MihonCompatKit tests, 23/23 KamiCore tests, the optimized CLI build,
  and artifact upload. The iOS and IPA runs passed both build destinations and
  unsigned packaging respectively.
- Three plan-inspection regressions prove deterministic current-profile plans,
  explicit legacy lib 1.4 blockers, and malformed-APK failure. The optimized
  CLI batch audit continues after malformed entries, reports every subsequent
  artifact, and returns a nonzero final status.
- Four diagnostics regressions prove typed-only runtime recording and
  deduplication, DEX-symbol redaction, an actionable `.popular` report from a
  failed real BatCave source operation, and deterministic order-independent
  static aggregation across all four current profiles. Two optimized Windows
  measurement-corpus runs are byte-identical and contain none of the checked
  local/corpus path, APK filename, URL, authorization or proxy-authorization
  header, `Set-Cookie`, `Bearer`, `token=`, or `password=` markers. Safe DEX API
  identities containing `Cookie` are expected. The current baseline is 15/15
  artifacts, 11 structural candidates, 540 unique unregistered surfaces, and
  zero unsupported opcodes.
- Seven focused interceptor-chain regressions cover application/network order,
  exact Request/tag identity, bounded response rebuilding, one-shot `proceed`,
  client limits, shared VM budget, `await` versus `awaitSuccess`, and
  cancellation.
- Six verifier regressions cover the six real Keiyoushi v2 APKs (Akuma, MangaDex,
  BatCave, Kawii Manga, MangaMelon, and Baozi Manhua), AOSP v1 and v3,
  verified certificate rotation, signed-content and signer-signature tampering,
  unsigned input, fingerprint normalization, and v3-block stripping. The
  pre-Baozi exact-head macOS CI run's 23 KamiCore tests cover persisted
  repository/user trust, unrelated-signer
  rejection, source-ID capability admission, rotation-aware updates,
  downgrade/same-version replacement rejection, repository-key persistence,
  exact-file startup restoration, install confirmation, enabled state, and
  Browse routing for popular/latest/text/filter-only requests, plus bounded
  reader settings, prefetch, and image-pipeline behavior; 12 are portable on
  Windows.
- The real-extension source/execution suites require exact successful values or exact typed
  boundaries. The BatCave popular, text-search, latest, details, and chapter
  and page tests require exact requests and parsed model fields; invalid
  chapter/page JSON requires typed serialization failures, and its 503 test
  requires the exact Mihon `HttpException` code. The Kawii test requires every
  core source result, exact dynamic URL, and custom request header. MangaMelon's
  tests require exact filters, every core result and form JSON, plus rejection
before transport when the app-provided filter schema is changed. Baozi's suite
additionally requires its exact preference keys/value domains, five-entry
filter schema, a valid non-default tag state that changes the request, core
source results, and interpreted image-request rewrite.
- Three pinned BatCave adapter tests cover every currently claimed `KamiSource`
  operation and default image request, reject a one-byte APK mutation before
  parsing, and prove concurrent callers are serialized; the Kawii and
  MangaMelon end-to-end tests cover the second and third exact profiles; the
  Baozi suite covers the fourth. KamiCore factory tests prove admitted
  construction, including Baozi, and registry tests prove insertion/source-ID
  deduplication.
- Seven focused HTML regressions cover the BatCave selectors, modern direct-child
  relative-selector and `:containsData` semantics, URL resolution, invalid bases,
  input/node/depth/attribute limits, selector syntax/length/result and
  cumulative-work limits, and extracted-string bounds.
- Four focused async regressions prove nested DEX-frame resumption, the typed
  sync-entry diagnostic, DEX handler re-entry, cancellation, and bounded
  response/body/charset/closed-state behavior.
- Fifteen focused dispatch regressions prove runtime-receiver virtual/class
  override selection, lexical normal/range class-super behavior, inherited and
  maximally specific interface defaults, abstract masking, default conflicts,
  interface-super selection/version gating, strict runtime interface receivers,
  typed linkage failures, and conservative unknown/native boundaries.
- Forty-seven focused pre-execution-verifier tests cover complete instruction
  decoding, instruction-boundary control flow, payload alignment/family/size,
  switch targets and sparse ordering, array-data element widths, AOSP branch
  and result rules, strict typed/catch-all exception-table decoding, dead-code
  register bounds, parameter seeding, normal/exception-edge category dataflow,
  joins, exact primitive families, polymorphic constants, typed conversions and
  wide pairs, allocation-specific constructor/uninitialized-object state,
  resolved reference assignments/common-superclass joins, array covariance,
  `Throwable` catch validation, and typed `move-exception` state.
- Four focused runtime regressions cover resolved and unresolved typed-catch
  dispatch plus hierarchy-aware `check-cast` and `instance-of` behavior.
- One focused arithmetic regression covers AOSP's operation/type-major binary
  opcode ordering across int, long, float, double, and `/2addr` instructions.
- Thirteen focused request/Kotlin-helper tests verify the pure request model,
  Kotlin duration/string/collection/time behavior, URL-builder encoding and
  work bounds, nullable equality, output/input bounds, scheme rejection, and
  CRLF-header rejection.
- Eight focused transport tests cover source isolation, redirect policy,
  bounded encoding/streaming, cancellation, and cookie scope.
- Parser hardening covers checksum/size/count limits and every truncated prefix
  of generated valid DEX and ZIP fixtures.
- Exact-head Swift CI built `compat-audit` in release mode and uploaded it; the
  current checkout also builds it locally in release mode.

## Honest frontier

Kami can download, validate structurally, inspect, classify, and execute four
controlled real-extension profiles through bounded async response delivery.
BatCave, Kawii, MangaMelon, and Baozi produce exact
popular/search/latest/details/chapters/pages compatibility models; MangaMelon
and Baozi additionally prove static filtered search, while BatCave reaches the
app-facing registry seam and validated default page image requests. Baozi also
proves its bounded scalar preference surface and interpreted image-request host
rewrite. These are four exact measured profiles, not a claim that downloaded
extensions are generally compatible. Signer trust,
durable install/update, exact-byte startup restoration, selection UI,
capability-consuming construction, stable public wrapper routing, and Browse
registration are working. Browse renders every app-facing filter case,
preserves the full source filter shape for text search, and supports
blank-query static filtered search. Typed runtime compatibility reports and a
non-executing static gap/corpus audit are working without changing admission;
the broader 15-artifact current-lib-1.6 measurement corpus is now locked and
fully analyzed, so corpus expansion is no longer open. App export UX, deeper
first-gap/field instrumentation, and regression promotion remain open. Automatic
catalog expansion, dynamic filter sources, production preference UI/persistence,
and arbitrary custom image-request overrides remain open. Source operations now
execute the bounded OkHttp interceptor chain, but the reader image seam still
drops DEX `Request` identity/tags and bypasses it. Baozi banner cropping,
redirect-domain rewriting, and missing-image behavior are therefore not proven
through reader image loads. Remaining
reader chapter retry uses a structured `.task(id: reloadID)` and dismissal
invalidates the load generation; per-page retry still reuses its resolved
`ImageRequest`, so retry-time request regeneration/expiry remains deferred.
Reader image fetching now inherits each source's admitted transport policy,
defaults to HTTPS-only, validates initial URL/headers before transport, and
permits HTTP only through explicit source opt-in; redirects use the same
source-scoped policy. The regex
helper is size-bounded but lacks a worst-case match-step/time bound; bounded or
linear-time hardening remains deferred. Remaining
DEX work (notably
broader external hierarchy and super/default resolution beyond parsed class
graphs, opcode coverage, and differential semantics) is tracked in
[#1](https://github.com/taizaki69/Kami/issues/1), the completed first pinned
source in [#2](https://github.com/taizaki69/Kami/issues/2), completed APK signer
trust in [#3](https://github.com/taizaki69/Kami/issues/3), and privacy-safe
compatibility telemetry in [#4](https://github.com/taizaki69/Kami/issues/4).
