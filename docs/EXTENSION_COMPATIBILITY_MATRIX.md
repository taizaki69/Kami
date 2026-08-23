# Extension Compatibility Matrix

**Last updated:** 2026-08-22

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
| DEX execution | Partial M1/M2 working | 91 interpreter tests plus eight exact assertions against pinned APK paths; method/exception geometry, exact primitive/constructor/reference dataflow, resolved catch validation, runtime casts/catches, overload identity, invoke shape/kind, lexical super dispatch, interface defaults, and AOSP binary-op ordering are checked |
| End-to-end source operations | Not implemented | BatCave popular constructs an exact inert POST request and reaches `awaitSuccess`; no interpreted response or network operation completes yet |

## Per-extension execution

| Extension | Version | SHA-256 | Loads | Constructor | Metadata methods | Search | Details | Chapters | Pages |
|---|---:|---|:---:|:---:|---|:---:|:---:|:---:|:---:|
| MangaDex (`all.mangadex`) | 1.4.212 | `543dcf6a…306fa3` | ✅ | ✅ | — | — | — | — | — |
| Akuma (`all.akuma`) | 1.4.10 | `9f5e744e…ba39a` | ✅ | ✅ | — | — | — | — | — |
| BatCave (`en.batcave`) | 1.6.9 | `f5338a90…34fab6` | ✅ | ✅ | ✅ base URL, lang, name, ID | — | — | — | — |

All three constructors execute their real no-argument DEX paths and return
objects of the declared entry type. BatCave's popular path additionally proves
class initialization, filter construction and iteration, its Kotlin ABI, and
bounded OkHttp request construction. It asserts the exact POST URL and ordered
form fields, then asserts the unresolved
`OkHttpExtensionsKt.awaitSuccess(Call, Continuation)` call. That is a precise
transport frontier, not a successful popular operation.

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

- 126/126 MihonCompatKit tests pass locally on Windows/Swift 6.3.3 with the
  corpus present and on the exact `f36a07a` baseline in
  [macOS Swift CI](https://github.com/taizaki69/Kami/actions/runs/32617590375).
- Seven real-extension constructor/getter tests require successful return
  values. The eighth requires the exact request value and `awaitSuccess`
  frontier; arbitrary VM failures are not accepted as progress.
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
- Two focused host-bridge tests verify the pure request model, Kotlin duration
  conversion, size bounds, scheme rejection, and CRLF-header rejection.
- Parser hardening covers checksum/size/count limits and every truncated prefix
  of generated valid DEX and ZIP fixtures.
- `compat-audit` builds in release mode and is uploaded by Swift CI.

## Honest frontier

Kami can download, validate structurally, inspect, classify, and execute a
controlled real-extension path through pure request construction. It cannot yet
use an unmodified extension as a reader source. Remaining DEX work (notably
broader external hierarchy and super/default resolution beyond parsed class
graphs, opcode coverage, and differential semantics) is tracked in
[#1](https://github.com/taizaki69/Kami/issues/1), the first
complete source in [#2](https://github.com/taizaki69/Kami/issues/2), APK signer trust in
[#3](https://github.com/taizaki69/Kami/issues/3), and privacy-safe compatibility
telemetry in [#4](https://github.com/taizaki69/Kami/issues/4).
