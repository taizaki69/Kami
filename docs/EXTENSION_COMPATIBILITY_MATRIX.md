# Extension Compatibility Matrix

**Last updated:** 2026-08-23

**Corpus:** immutable Keiyoushi release assets fetched by
`scripts/fetch_corpus.sh` and verified against `Tests/corpus/manifest.json`.

This matrix separates structural loading, shallow VM execution, and full source
operations. A check mark means a concrete assertion passed; a dash means there
is no compatibility claim.

## Pipeline status

| Stage | Status | Evidence |
|---|---|---|
| Store index (`index.pb` + gzip) | Working | Live 2026-08-21 sample parsed 1,372 extensions, store metadata, external-list indirection, and signing-key metadata |
| Legacy JSON index | Working | Schema fixture decoded by `RepositoryIndexTests` |
| APK acquisition and durable install | Working | Repository entries download into content-addressed app storage; first trust uses the pinned repository key or explicit confirmation of an already-verified legacy-store signer; install/update and enable/disable state persist |
| APK signing identity | Working on locked v1/v2/v3 corpus | RSA PKCS#1/PSS and ECDSA signer signatures, AOSP chunked content digests, certificate/SPKI matching, v3 proof-of-rotation, stripping protection, exact Mihon SHA-256 fingerprints, and unsigned/tamper rejection are asserted before admission |
| ZIP + DEFLATE | Working | STORE/DEFLATE real APK entries parse with size limits, exact decoded size, and CRC-32 verification |
| Binary Android manifest | Working | Package, entry class, flags, and string/float `extensionLib` values extracted from real APKs |
| DEX structural parse | Working on locked corpus | Real corpus DEX files pass header/table/index/range checks plus Adler-32; the parser accepts the shared 035 and 037–040 header contract and rejects the different 041 container format |
| External-reference audit | Working heuristic | Cross-DEX definitions are reconciled before missing-class classification; class coverage is a priority signal, not method-level runtime proof |
| DEX execution | Partial M1/M2 working | The 179-test suite includes 18 exact pinned-APK source/execution paths; verified dispatch/dataflow semantics plus async nested-frame suspension, cancellation, typed handler re-entry, stable public-wrapper routing, bounded HTML/CSS, generated-serializer JSON encode/decode, page construction, and serialized adapter ownership are checked |
| Admission restoration and source factory | Working for exact measured profiles | Startup re-reads the enabled installed APK, rechecks hash/signature/signer history/user trust/manifest, and gives the sole factory a fresh capability; the factory repeats exact-byte authentication, rejects undeclared source IDs, and refuses unmeasured profiles |
| End-to-end source operations | Working for two exact profiles | BatCave 1.6.9 and Kawii Manga 1.6.1 expose metadata, popular/latest/search, details, chapters, and pages through `KamiSource`; BatCave additionally proves default image requests and the installed-source registry path. Automatic profile discovery, filtered-search semantics, preferences, custom image requests, and live-site availability remain open |

## Per-extension execution

| Extension | Version | SHA-256 | Loads | Constructor | Metadata methods | Popular | Search | Details | Chapters | Pages |
|---|---:|---|:---:|:---:|---|---|:---:|:---:|:---:|:---:|
| MangaDex (`all.mangadex`) | 1.4.212 | `543dcf6a…306fa3` | ✅ | ✅ | — | — | — | — | — | — |
| Akuma (`all.akuma`) | 1.4.10 | `9f5e744e…ba39a` | ✅ | ✅ | — | — | — | — | — | — |
| BatCave (`en.batcave`) | 1.6.9 | `f5338a90…34fab6` | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ paginated text query | ✅ core fields | ✅ combined update | ✅ exact JSON POST + URLs |
| Kawii Manga (`ar.kawiimanga`) | 1.6.1 | `9e6110b8…dd52a` | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ text query | ✅ core fields | ✅ combined update | ✅ exact JSON GET + URLs |

All four constructors execute their real no-argument DEX paths and return
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
the no-next-page result. Filtered search is not yet covered.

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

`PinnedInterpretedSource` accepts only the locked BatCave or Kawii bytes after
exact SHA-256, APK signer fingerprint, manifest package/lib/entry-class, and
DEX class checks. For downloaded execution, `ExtensionAdmissionService.restore`
first re-authenticates the enabled durable installation and
`ExtensionSourceFactory` rechecks the exact immutable bytes before selecting
this profile. It owns one
source-scoped interpreter and transport behind a bounded cancellation-aware
queue, maps every operation above into `KamiSource`, reuses the combined update
for one-request library refreshes, validates default HTTP(S) page image
requests, and registers in KamiCore without source-kind branches. Three BatCave
adapter tests prove the complete deterministic contract, pre-parse tamper
rejection, and no overlapping VM/transport entry under concurrent calls; one
Kawii test proves its complete measured core-operation contract.

## Current measured API workload

`compat-audit missing <apk> 10000` was run over the original three locked APKs
after multidex reference reconciliation. Kawii was separately inspected with
`methods` and `disasm`; the aggregate counts below have not been recomputed with
it, so they remain a prioritization snapshot rather than a four-APK total:

| Class | References |
|---|---:|
| `kotlin.collections.CollectionsKt` | 44 |
| `kotlin.text.StringsKt` | 31 |
| `java.lang.StringBuilder` | 24 |
| `java.util.ArrayList` | 20 |
| `java.lang.String` | 20 |
| `kotlin.time.Duration` | 18 |
| `kotlinx.serialization.encoding.CompositeDecoder` | 16 |
| `okhttp3.Response` | 16 |
| `okhttp3.HttpUrl` | 16 |
| `okhttp3.OkHttpClient$Builder` | 15 |
| `kotlinx.serialization.encoding.CompositeEncoder` | 14 |
| `java.util.List` | 14 |
| `okhttp3.Request$Builder` | 13 |
| `org.jsoup.nodes.Element` | 12 |

Some classes above have a small M1 host subset already (for example String and
StringBuilder) but remain in this table because the class-level analyzer does
not equate a few bridged methods with full class compatibility. Real method
tests, not the heuristic percentage, are the acceptance signal.

## Test evidence

- 179/179 MihonCompatKit tests pass locally on Windows/Swift 6.3.3 with the
  corpus present.
- Exact implementation commit `3802653` passes
  [Swift CI 32670599504](https://github.com/taizaki69/Kami/actions/runs/32670599504),
  [iOS Build 32670599479](https://github.com/taizaki69/Kami/actions/runs/32670599479),
  and [IPA Package 32670599498](https://github.com/taizaki69/Kami/actions/runs/32670599498).
- Six verifier regressions cover three real Keiyoushi v2 APKs, AOSP v1 and v3,
  verified certificate rotation, signed-content and signer-signature tampering,
  unsigned input, fingerprint normalization, and v3-block stripping. Eighteen
  macOS KamiCore tests cover persisted repository/user trust, unrelated-signer
  rejection, source-ID capability admission, rotation-aware updates,
  downgrade/same-version replacement rejection, repository-key persistence,
  exact-file startup restoration, install confirmation, and enabled state.
- Eighteen real-extension source/execution tests require exact successful values or exact typed
  boundaries. The BatCave popular, text-search, latest, details, and chapter
  and page tests require exact requests and parsed model fields; invalid
  chapter/page JSON requires typed serialization failures, and its 503 test
  requires the exact Mihon `HttpException` code. The Kawii test requires every
  core source result, exact dynamic URL, and custom request header.
- Three pinned BatCave adapter tests cover every currently claimed `KamiSource`
  operation and default image request, reject a one-byte APK mutation before
  parsing, and prove concurrent callers are serialized; the Kawii end-to-end
  test covers its second exact profile. A KamiCore test proves registry
  insertion and source-ID deduplication.
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
- `compat-audit` builds in release mode and is uploaded by Swift CI.

## Honest frontier

Kami can download, validate structurally, inspect, classify, and execute two
controlled real-extension profiles through bounded async response delivery.
BatCave and Kawii both produce exact popular/search/latest/details/chapters/pages
compatibility models; BatCave also reaches the app-facing registry seam and
validated default page image requests. These are two exact measured profiles,
not a claim that downloaded extensions are generally compatible. Signer trust,
durable install/update, exact-byte startup restoration, selection UI,
capability-consuming construction, stable public wrapper routing, and Browse
registration are working. Automatic profile discovery beyond the exact
catalog, filtered-search semantics, preferences, and custom image-request
overrides remain open. Remaining
DEX work (notably
broader external hierarchy and super/default resolution beyond parsed class
graphs, opcode coverage, and differential semantics) is tracked in
[#1](https://github.com/taizaki69/Kami/issues/1), the completed first pinned
source in [#2](https://github.com/taizaki69/Kami/issues/2), completed APK signer
trust in [#3](https://github.com/taizaki69/Kami/issues/3), and privacy-safe
compatibility telemetry in [#4](https://github.com/taizaki69/Kami/issues/4).
