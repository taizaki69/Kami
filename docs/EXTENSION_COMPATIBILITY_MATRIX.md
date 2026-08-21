# Extension Compatibility Matrix

**Last updated:** 2026-08-21
**Method:** every row below was produced by actually running Kami code (the
`compat-audit` tool, built from `Packages/MihonCompatKit`) against the real
extension APK downloaded from the live Keiyoushi store index on the date
above. Nothing in this table is inferred or estimated.

## Pipeline status (measured)

| Stage | Status | Evidence |
|---|---|---|
| Store index fetch (`index.pb`, gzip) | **Working** | Parsed live index: 1372 extensions, store "Keiyoushi", badge "KEI", signing key present |
| Legacy JSON index (`index.min.json`) | **Working** | Unit-tested against the schema served by the live repo (stub entries today) |
| APK download | **Working** | 3 real APKs fetched from `github.com/keiyoushi/extensions/releases` |
| ZIP parse + DEFLATE inflate | **Working** | All entries listed; `classes.dex` inflated byte-identical to Python zlib reference (119,972/119,972 bytes, 0 diffs) |
| Binary `AndroidManifest.xml` (AXML) | **Working** | Package, `tachiyomix.name`, `tachiyomi.extension.class`, nsfw, contentWarning, `extensionLib` (float-typed) all extracted |
| DEX structural parse | **Working** | MangaDex dex: 1370 strings / 352 types / 297 protos / 280 fields / 831 methods / 127 classes — all counts match an independent Python parser |
| External-reference audit | **Working** | Missing-class lists below |
| **Source execution (DEX interpreter)** | **Not started** | See docs/EXTENSION_RUNTIME.md — this is the multi-quarter track |

## Per-extension results (real APKs, 2026-08-21)

Compatibility criteria from the mission: Loads = APK opens, manifest + all
DEX structural tables parse, declared source class is found. Search/details/
chapters/pages require the runtime and are honestly marked —.

| Extension | Version | Lib | Loads | Search | Details | Chapters | Pages | Notes |
|---|---|---|---|---|---|---|---|---|
| `all.mangadex` | 1.4.212 | 1.4 | ✅ | — | — | — | — | 127 classes; 151 external refs; nsfw flag legacy=1 |
| `all.akuma` | 1.4.10 | 1.4 | ✅ | — | — | — | — | multisrc style (27 sources), single generated class |
| `en.batcave` | 1.6.9 | 1.6 | ✅ | — | — | — | — | current tachiyomix 1.6 API shape |

✅ = measured working · — = requires the DEX runtime (not yet implemented)

## Measured compatibility workload (what the runtime must cover)

Aggregate external references across the corpus, by reference count — this is
the priority order for runtime API implementation:

| Class | Refs | Category |
|---|---|---|
| kotlin.collections.CollectionsKt | 32 | Kotlin stdlib |
| java.lang.String | 10 | Java stdlib |
| androidx.preference.ListPreference | 10 | Extension prefs UI |
| kotlin.text.StringsKt | 22 | Kotlin stdlib |
| kotlin.time.Duration | 15 | Kotlin stdlib |
| java.lang.StringBuilder | 15 | Java stdlib |
| androidx.preference.* (5 classes) | 38 | Extension prefs UI |
| kotlinx.serialization.* | 21 | Serialization |
| java.util.ArrayList / List | 13 | Java collections |
| okhttp3.HttpUrl | 7 | Networking |
| android.content.SharedPreferences$Editor | 5 | Preferences storage |

(Counts from `compat-audit missing <apk>` over the 3-APK corpus; extend the
corpus via `scripts/fetch_corpus.sh` to grow this table.)

## Ecosystem facts learned from the corpus (2026-08)

- Current extensions declare a single generated entry class
  (`tachiyomi.extension.class = .ExtensionGenerated`), even for multisrc
  extensions with 27 sources — `SourceFactory` appears legacy.
- `tachiyomix.extensionLib` may be serialized as a **float** typed value
  (0x04), not a string — the AXML layer handles both.
- The live `index.min.json` at keiyoushi now contains only migration stubs;
  the real catalog is the protobuf index (`index.pb`, gzip-wrapped by GitHub
  raw).

## Honest summary

- **What works today:** everything up to and including structural DEX
  analysis of real, current extension APKs — on iOS-ready, pure-Swift,
  zero-dependency code, all unit/integration tested (9/9 tests green).
- **What does not work yet:** executing extension source logic. Until the DEX
  interpreter + Kotlin/Java class library land, Kami reads through native
  sources (MangaDex) and the extension manager can browse/download/analyze
  but not run extensions.
