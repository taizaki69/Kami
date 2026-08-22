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
| DEX execution | Initial M1 working | 23 interpreter tests plus six exact assertions against methods in pinned APKs |
| End-to-end source operations | Not implemented | No interpreted search/details/chapters/pages/network claim yet |

## Per-extension execution

| Extension | Version | SHA-256 | Loads | Constructor | Metadata methods | Search | Details | Chapters | Pages |
|---|---:|---|:---:|:---:|---|:---:|:---:|:---:|:---:|
| MangaDex (`all.mangadex`) | 1.4.212 | `543dcf6a…306fa3` | ✅ | ✅ | — | — | — | — | — |
| Akuma (`all.akuma`) | 1.4.10 | `9f5e744e…ba39a` | ✅ | ✅ | — | — | — | — | — |
| BatCave (`en.batcave`) | 1.6.9 | `f5338a90…34fab6` | ✅ | — | ✅ base URL, lang, name, ID | — | — | — | — |

BatCave's metadata assertions use a valid allocated receiver. Its full
constructor currently reaches unsupported Java reflection
(`Class.getDeclaredField`), so constructor compatibility is deliberately not
claimed. MangaDex and Akuma constructors execute their real no-argument DEX
paths and return objects of the declared entry type.

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

- 54/54 MihonCompatKit tests pass locally on Windows/Swift 6.3.3 and in macOS
  GitHub Actions with the corpus present.
- The six real-extension tests require successful return values; arbitrary VM
  failures are not accepted as success.
- Parser hardening covers checksum/size/count limits and every truncated prefix
  of generated valid DEX and ZIP fixtures.
- `compat-audit` builds in release mode and is uploaded by Swift CI.

## Honest frontier

Kami can download, validate structurally, inspect, classify, and execute a
small controlled slice of real extension bytecode. It cannot yet use an
unmodified extension as a reader source. Full DEX verification/opcode work is
tracked in [#1](https://github.com/taizaki69/Kami/issues/1), the first complete
source in [#2](https://github.com/taizaki69/Kami/issues/2), APK signer trust in
[#3](https://github.com/taizaki69/Kami/issues/3), and privacy-safe compatibility
telemetry in [#4](https://github.com/taizaki69/Kami/issues/4).
