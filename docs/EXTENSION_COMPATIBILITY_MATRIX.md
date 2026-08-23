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
| APK acquisition | Working | Three immutable release assets downloaded and SHA-256 checked in local and CI corpus setup |
| ZIP + DEFLATE | Working | STORE/DEFLATE real APK entries parse with size limits, exact decoded size, and CRC-32 verification |
| Binary Android manifest | Working | Package, entry class, flags, and string/float `extensionLib` values extracted from real APKs |
| DEX structural parse | Working on locked corpus | Real corpus DEX files pass header/table/index/range checks plus Adler-32; the parser accepts the shared 035 and 037–040 header contract and rejects the different 041 container format |
| External-reference audit | Working heuristic | Cross-DEX definitions are reconciled before missing-class classification; class coverage is a priority signal, not method-level runtime proof |
| DEX execution | Partial M1/M2 working | The 165-test suite includes 17 exact pinned-APK paths; verified dispatch/dataflow semantics plus async nested-frame suspension, cancellation, typed handler re-entry, bounded HTML/CSS, generated-serializer JSON encode/decode, page construction, and serialized adapter ownership are checked |
| End-to-end source operations | Working for one pinned profile | The exact BatCave 1.6.9 APK exposes metadata, popular, paginated text search, latest, core details, combined chapter updates, pages, and default image requests through `KamiSource`; filtered search, preferences, custom image requests, live-site availability, and arbitrary APK admission remain open |

## Per-extension execution

| Extension | Version | SHA-256 | Loads | Constructor | Metadata methods | Popular | Search | Details | Chapters | Pages |
|---|---:|---|:---:|:---:|---|---|:---:|:---:|:---:|:---:|
| MangaDex (`all.mangadex`) | 1.4.212 | `543dcf6a…306fa3` | ✅ | ✅ | — | — | — | — | — | — |
| Akuma (`all.akuma`) | 1.4.10 | `9f5e744e…ba39a` | ✅ | ✅ | — | — | — | — | — | — |
| BatCave (`en.batcave`) | 1.6.9 | `f5338a90…34fab6` | ✅ | ✅ | ✅ base URL, lang, name, ID | ✅ popular + latest | ✅ paginated text query | ✅ core fields | ✅ combined update | ✅ exact JSON POST + URLs |

All three constructors execute their real no-argument DEX paths and return
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

`PinnedInterpretedSource` admits only the locked BatCave bytes after exact
SHA-256, manifest package/lib/entry-class, and DEX class checks. It owns one
source-scoped interpreter and transport behind a bounded cancellation-aware
queue, maps every operation above into `KamiSource`, reuses the combined update
for one-request library refreshes, validates default HTTP(S) page image
requests, and registers in KamiCore without source-kind branches. Three adapter
tests prove the complete deterministic contract, pre-parse tamper rejection,
and no overlapping VM/transport entry under concurrent calls.

## Current measured API workload

`compat-audit missing <apk> 10000` was run over all three locked APKs after
multidex reference reconciliation. These are the largest aggregate external
class-reference counts still classified as missing:

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

- 165/165 MihonCompatKit tests pass locally on Windows/Swift 6.3.3 with the
  corpus present.
- Exact-head commit `3708aa1` passes
  [Swift CI 32662751000](https://github.com/taizaki69/Kami/actions/runs/32662751000),
  [iOS Build 32662750970](https://github.com/taizaki69/Kami/actions/runs/32662750970),
  and [IPA Package 32662751023](https://github.com/taizaki69/Kami/actions/runs/32662751023).
- Seventeen real-extension tests require exact successful values or exact typed
  boundaries. The BatCave popular, text-search, latest, details, and chapter
  and page tests require exact requests and parsed model fields; invalid
  chapter/page JSON requires typed serialization failures, and its 503 test
  requires the exact Mihon `HttpException` code.
- Three pinned adapter tests cover every currently claimed `KamiSource`
  operation and default image request, reject a one-byte APK mutation before
  parsing, and prove concurrent callers are serialized. A KamiCore test proves
  registry insertion and source-ID deduplication.
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
- Forty-six focused pre-execution-verifier tests cover complete instruction
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
- Seven focused request/Kotlin-helper tests verify the pure request model, Kotlin
  duration/string behavior, output/input bounds, scheme rejection, and
  CRLF-header rejection.
- Eight focused transport tests cover source isolation, redirect policy,
  bounded encoding/streaming, cancellation, and cookie scope.
- Parser hardening covers checksum/size/count limits and every truncated prefix
  of generated valid DEX and ZIP fixtures.
- `compat-audit` builds in release mode and is uploaded by Swift CI.

## Honest frontier

Kami can download, validate structurally, inspect, classify, and execute a
controlled real-extension path through bounded async response delivery and
parse BatCave popular/search/latest/details/chapters/pages into exact
compatibility models. The exact locked APK now reaches the app-facing source
and registry seams and produces validated default page image requests. This is
one compiled pinned profile, not a claim that downloaded extensions are safe or
generally compatible; signer trust, installation/selection UI, filtered
search, preferences, and custom image-request overrides remain open. Remaining
DEX work (notably
broader external hierarchy and super/default resolution beyond parsed class
graphs, opcode coverage, and differential semantics) is tracked in
[#1](https://github.com/taizaki69/Kami/issues/1), the completed first pinned
source in [#2](https://github.com/taizaki69/Kami/issues/2), APK signer trust in
[#3](https://github.com/taizaki69/Kami/issues/3), and privacy-safe compatibility
telemetry in [#4](https://github.com/taizaki69/Kami/issues/4).
