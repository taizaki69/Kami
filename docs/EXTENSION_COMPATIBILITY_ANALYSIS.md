# Extension Compatibility Analysis

**Date:** Ecosystem research verified 2026-08-21; local corpus measurement updated 2026-09-03
**Scope:** Current (2025–2026) Mihon extension ecosystem, verified against primary sources.

The ecosystem research was verified on 2026-08-21 against the repositories
listed in [Sources](#sources); the local corpus evidence in section 6.1 was
remeasured on 2026-09-03. Where a claim could not be verified, it is marked
**unverified**.

---

## 1. What a Mihon extension actually is today

A Mihon extension is an **unsigned-for-distribution, signed-with-a-repo-key Android APK**
containing Kotlin code compiled to Dalvik bytecode (`classes.dex`). It is *not* a
platform-neutral package. Concretely:

- Compiled against **`tachiyomix`** (current version **1.6**, with 1.7 APIs landing),
  a `compileOnly` Kotlin stub library that reproduces the historical
  `eu.kanade.tachiyomi.*` source API surface. Host apps provide the real
  implementations at runtime. ([mihonapp/tachiyomix](https://github.com/mihonapp/tachiyomix))
- Mihon **0.20.0+** added support for "tachiyomix 1.6 extensions and index format";
  Keiyoushi's rebuilt repository made Mihon **0.20.1+** a hard requirement
  ([Mihon changelog](https://mihon.app/changelogs/v0.20.0),
  [community reports](https://www.reddit.com/r/mangapiracy/comments/1v71z3z/recent_announcement_about_the_extension_updates/)).
- The APK manifest declares extension metadata (see §3). There is **no JavaScript,
  no WASM, no IR** in the current ecosystem. The extension logic is DEX bytecode
  executing against the host app's Android/Java/Kotlin runtime.

A persistent rumor claims current extensions are "~99% JavaScript". **This is false.**
Tachiyomix is a Kotlin library; keiyoushi extensions-source builds APKs with Gradle.
(Tachimanga, an unrelated iOS app, has its own JS-based extension system — see §7.)

## 2. The extension API surface (tachiyomix 1.6/1.7)

Verified from the tachiyomix source tree
(`library/src/main/java/...`, fetched 2026-08-21):

### 2.1 Source interfaces

| Symbol | Notes |
|---|---|
| `eu.kanade.tachiyomi.source.Source` | `id: Long`, `name`, `language` (BCP-47, since 1.7), `supportsLatest`, **suspend** `getPopularManga/getLatestUpdates/getSearchManga/getMangaUpdate/getPageList`, `getFilterList()` |
| `...source.CatalogueSource` | deprecated alias of `Source` (still what `HttpSource` implements) |
| `...source.ConfigurableSource` | `fun setupPreferenceScreen(screen: PreferenceScreen)` |
| `...source.SourceFactory` | `fun createSources(): List<Source>` (multisource extensions) |
| `...source.UnmeteredSource` | marker interface |

API evolution of note:

- The legacy **RxJava** `fetch*` methods (`fetchMangaDetails`, `fetchChapterList`,
  `fetchPageList`, `fetchPopularManga`, …) still exist but are deprecated.
- tachiyomix 1.6 introduces **`getMangaUpdate(manga, chapters, fetchDetails, fetchChapters): SMangaUpdate`**
  — a combined details+chapters fetch — and **`getImageUrl(page)`** as a suspend
  alternative to `fetchImageUrl`.
- `HttpSource`'s former request/parse template methods
  (`popularMangaRequest`, `searchMangaParse`, …) are **deprecated**, so new
  extensions may inline all logic in the suspend methods. A compatibility engine
  cannot rely on intercepting the request/parse pairs; it must support arbitrary
  method bodies.

### 2.2 `HttpSource` / `ParsedHttpSource`

`HttpSource` (abstract class) exposes to subclasses:

- `network: NetworkHelper` (host-provided: `client`, `cookieJar`, `requests`, …)
- `client: OkHttpClient` (overridable per source — e.g. Cloudflare-flavored clients)
- `headers: Headers` / `headersBuilder()`
- `baseUrl`, `versionId`, computed `id` (first 64 bits of MD5 of `name/lang/versionId`, sign bit cleared)
- URL helpers: `setUrlWithoutDomain`, `getMangaUrl`, `getChapterUrl`
- `imageRequest(page)` (overridable; used for headers/referer on image fetches)

`ParsedHttpSource` adds Jsoup-based hooks (`popularMangaSelector`,
`searchMangaFromElement`, `chapterListParse`, `pageListParse`, `detailsParse` …) and
`rxHtml`/`asJsoup` extensions live in `util/JsoupExtensions.kt`.

### 2.3 Models

- `SManga` — `url, title, altTitles, thumbnail_url, banner, artist, author, status
  (0=UNKNOWN..6=ON_HIATUS), language, contentRating (SAFE/SUGGESTIVE/ADULT), score,
  description, genre(s), readingMode (RTL/LTR/LONG_STRIP), update_strategy, memo
  (kotlinx JSON `JsonObject`), initialized`. `create()` factory is host-provided.
- `SChapter` — `url, name, volume, chapter_number (Float, deprecated) , number (String?,
  new), scanlator (deprecated) / scanlators (List<String>), date_upload (epoch ms),
  language, locked, note, memo (JsonObject)`.
- `Page(index, url, imageUrl, uri?)` — `uri` is an Android `Uri`, used by local sources.
- `MangasPage(mangas, hasNextPage)`, `SMangaUpdate`, `UpdateStrategy`.
- `Filter` sealed class: `Header`, `Separator`, `Select<V>`, `Text`, `CheckBox`,
  `TriState` (IGNORE/INCLUDE/EXCLUDE), `Group<V>`, `Sort` (with `Selection`).
  Mutated in place by the host via `state`; extensions read `state` when building
  requests.

### 2.4 Host-provided dependencies (what the APK's DEX expects at runtime)

From tachiyomix README "App Dependency Requirements" (v1.6):

| Dependency | Version |
|---|---|
| Kotlin stdlib | 2.4.0 |
| kotlinx-coroutines | 1.10.2 |
| kotlinx-serialization (json, json-okio, protobuf) | 1.7.3 |
| OkHttp (incl. brotli, zstd) | 5.4.0 |
| Jsoup | 1.22.2 |
| Injekt (DI) | 91edab2317 |

Plus the Android stubs shipped inside tachiyomix itself: `android.content.Context`,
and `androidx.preference.*` (`Preference`, `PreferenceScreen`, `SwitchPreferenceCompat`,
`CheckBoxPreference`, `EditTextPreference`, `ListPreference`,
`MultiSelectListPreference`, `TwoStatePreference`, `DialogPreference`).

In practice extension DEX also references (from historical corpus knowledge;
**verify per-extension with `scripts/compat_audit.py` / the in-app analyzer**):
`java.lang.*` / `java.util.*` (regex, UUID, Base64…), `org.json`, `kotlin.text.Regex`
(backed by `java.util.regex.Pattern`), `android.net.Uri`, `android.util.Base64`,
`android.webkit.WebView` (Cloudflare interceptors in some forks), `javax.crypto`
(AES/DES for obfuscated sources), `java.math.BigInteger` (RSA/DH key exchange).

## 3. APK manifest metadata (how sources are discovered)

Verified in Mihon's `extension/util/ExtensionLoader.kt` and tachiyomix README:

```xml
<uses-feature android:name="tachiyomi.extension" />
<meta-data android:name="tachiyomix.name"             android:value="…" />  <!-- display name -->
<meta-data android:name="tachiyomix.contentWarning"   android:value="0" />  <!-- 0 safe /1 mixed /2 nsfw -->
<meta-data android:name="tachiyomix.extensionLib"     android:value="1.6"/>
<meta-data android:name="tachiyomi.extension.class"   android:value=".MySource" />
<meta-data android:name="tachiyomi.extension.factory" android:value=".MyFactory" /> <!-- multisrc -->
<meta-data android:name="tachiyomi.extension.nsfw"    android:value="…" />   <!-- legacy -->
```

Class names may be relative to the APK package name. Mihon loads extensions from
installed packages **and** from private files (`files/exts/<pkg>.ext`) using a
`ChildFirstPathClassLoader` (a `DexClassLoader` subclass), after verifying the APK
signature against the trusted repository signing key (`TrustExtension`,
`GET_SIGNATURES`). Extension APKs are expected to be signed with the repo's key.

## 4. Repository / "extension store" index formats

Two formats coexist (both verified):

### 4.1 Legacy JSON index (`index.min.json` / `index.json`)

Array of objects:

```json
{ "name": "…", "pkg": "eu.kanade.tachiyomi.extension.en.mangadex",
  "apk": "tachiyomi-en.mangadex-v1.4.1.apk", "lang": "en", "code": 21,
  "version": "1.4.1", "nsfw": 0,
  "sources": [ { "name": "MangaDex", "lang": "en", "id": "2499283573021220255",
                 "baseUrl": "https://mangadex.org" } ] }
```

APKs are served relative to the index URL. As of 2026-08-21 the keiyoushi legacy
index contains only two stub entries ("Outdated App", "Update to Mihon 0.20.1+")
pointing users to the new store system — the real catalog moved to the new format.

### 4.2 New protobuf index (`index.pb`)

Schema: `mihonapp/tachiyomix/index/index.proto` (proto3):

```proto
message Index {
  string name = 1;            // store display name
  string badgeLabel = 2;
  string signingKey = 3;      // public signing key to verify extension APKs
  Contact contact = 4;
  oneof extensions { ExtensionList extensionList = 101; string extensionListUrl = 102; }
}
message Extension {
  string name = 1; string packageName = 2;
  Resources resources = 3;    // apkUrl, iconUrl (absolute URLs now, not relative)
  string extensionLib = 4; int64 versionCode = 5; string versionName = 6;
  ContentWarning contentWarning = 7; repeated Source sources = 8;
}
message Source { int64 id = 1; string name = 2; string language = 3;
  string homeUrl = 4; repeated string mirrorUrls = 5; optional string message = 7; }
```

Mihon's settings UI is now "Extension stores"; terminology renamed in 0.20.0
(repo → store, obsolete → orphaned).

## 5. Backup format (`.tachibk`)

Mihon backups are a **zstd-compressed protobuf** stream. Protobuf messages are
generated with kotlinx.serialization.protobuf annotations
(`data/backup/models/Backup*.kt`, `@ProtoNumber` field tags): `Backup` (backupManga,
backupCategories, backupSources, backupPreferences, backupExtensionStores, …),
`BackupManga` (url, title, artist, author, description, genre, status, chapters,
categories, history, tracking, …), `BackupChapter` (url, name, scanlator,
read, bookmark, lastPageRead, …), `BackupSource` (sourceId, name), `BackupHistory`.
Full schema is codified in `Backup.kt` and per-model files. Import compatibility
requires: protobuf wire decoding + zstd decompression + source-ID → installed
extension mapping.

## 6. Strategies assessed for iOS

### A — DEX compatibility runtime (interpreter)
An in-process Dalvik interpreter written in Swift executing `classes.dex` from
extension APKs, with a hand-built class library covering §2.4. **Technically
possible**: iOS forbids JIT and downloadable *native* code, but a pure interpreter
executing bytecode is not native machine code — this is the same category as
scripting engines and is permitted for sideloaded builds. (App Store guideline
2.5.2 restricts *downloaded executable code*; interpreted bytecode from external
sources is disallowed on the App Store without review caveats — this is why Kami
targets sideloading first, keeping an App Store flavor without the runtime.)

**Effort: very large.** The hard part is not the bytecode interpreter (the DEX
instruction set is small and tree-shaking-friendly) but the class library:
kotlinx-coroutines suspend state machines, OkHttp client semantics, Jsoup CSS
selectors, `java.util.regex` semantics, Injekt. None of this is impossible — it is
a volume problem with a long tail. No shipping iOS app has done it (§7), which is
evidence of effort, not impossibility.

### B — Kotlin source translation / C — portable IR
Requires a Kotlin frontend with full type inference, coroutines lowering, etc.
This is a compiler project larger than Strategy A, and fragile against obfuscated
DEX-only extensions (many keiyoushi multisrc APKs ship from source, but plenty of
extensions circulate only as APKs). Rejected as primary path.

### D — Generated native adapters
Works only where static analysis can fully recover semantics of every method an
extension calls (including Rx interop, DI graph). Good as an *accelerator* for the
simplest `ParsedHttpSource` shapes; cannot be the general strategy.

### E — Hybrid (chosen)
1. **Native app + native sources** so Kami is a real reader on day one
   (MangaDex API source, local CBZ/ZIP source, Komga planned).
2. **Repository compatibility** (both index formats, §4) — works **today**, implemented
   in `MihonCompatKit/Repository`.
3. **APK inspection + DEX analysis pipeline** (implemented: ZIP/inflate, binary
   AndroidManifest XML, DEX parsing, structural plans, and a deterministic
   redacted static method/opcode/blocker corpus audit) — the measurement
   instrument that drives which runtime APIs get implemented next, and powers the
   in-app Extension Analyzer + installability diagnostics.
4. **DEX interpreter track** (`MihonCompatKit/Dex/Runtime`): the initial M1
   engine now executes pinned real constructors and metadata getters. A
   bounded pre-execution verifier covers instruction/payload geometry and
   control-flow targets, strict try/catch table decoding, static register bounds,
   exact primitive-family dataflow, polymorphic constants, typed wide pairs,
   allocation-specific constructor/uninitialized-reference rules, resolved
   reference assignment and common-supertype joins, `Throwable` catch
   validation, and typed exception edges. Runtime casts and catch dispatch use
   the same parsed-DEX plus bounded-host hierarchy. Runtime method selection
   now covers lexical class/interface `invoke-super` and maximally specific
   interface defaults within the parsed graph, with conservative unresolved
   outcomes at incomplete external boundaries. Broader external hierarchy,
   opcode, and host-API coverage remain driven by the audit corpus.
   This is the long-running engineering track; see
   `EXTENSION_RUNTIME.md` for the staged plan and honest status.
5. **Backup import** (.tachibk protobuf+zstd) independent of the runtime, so users
   can migrate libraries before extension compat reaches their sources.

### 6.1 Current local corpus measurement (2026-09-03)

The local Kami corpus now locks 27 APK artifacts: eight real Keiyoushi execution
fixtures, 13 current lib 1.6 Keiyoushi measurement-only fixtures under
`Tests/corpus/measurement/`, and six AOSP apksig conformance fixtures. The
current lib 1.6 total is 19 (six execution fixtures plus the 13 measurement
fixtures). The artifacts were selected by behavior family and shape, not as a
statistical sample.

The measurement artifacts are parsed, signature-verified for parser
conformance, and statically audited only. Corpus membership never grants signer
trust, admission, installation, or execution. The deterministic audit analyzed
13/13 measurement APKs with zero errors, found nine structural candidates and
four stable-wrapper blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC), and
reported 511 unique unregistered external method surfaces with zero omitted
invocations and zero unsupported
opcodes. These are prioritization results, not runtime compatibility proof.

Baozi Manhua 1.6.29 is now the fourth exact execution profile. Its admission is
pinned to SHA-256
`7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`, signer
fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, the
authenticated manifest, and source ID `5724751873601868259`. Deterministic
fake-transport regressions execute popular, latest, text search, combined
details/chapters, and pages. They also assert one header plus four static
`Select` filters, bounded scalar preferences, and the DEX `imageRequest(Page)`
rewrite from `static.baozicdn.com` to `static.baozimh.com` without network I/O.

TuttoAnimeManga 1.6.10 is now the fifth exact execution profile. Its admission
is pinned to SHA-256
`e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3`, the same
authenticated Keiyoushi signer fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, the
manifest identity, and source ID `2102507871480604746`. Deterministic
fake-transport regressions execute popular, latest, text search,
details/chapters, and pages from the unmodified APK, including PizzaReader's
chapter-number, scanlator, pagination, and date conversions. The profile
exposes no filters or preferences; its page-URL image path preserves the
inherited `Referer`/`Origin` headers while source-derived credentials remain
origin-bound. These are offline assertions and do not
claim live-site availability or general PizzaReader compatibility.

Mangas-Origines.fr 1.6.58 is now the sixth exact execution profile. Its
admission is pinned to SHA-256
`b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b`, the same
authenticated Keiyoushi signer fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, the
manifest identity, and source ID `4803238581797687746`. Deterministic
fake-transport regressions execute metadata, popular, latest, text and filtered
search, details, chapters, pages, and its ordinary page-URL image request from
the unmodified APK. They also assert the exact seven-entry static filter graph
and reject altered filters or unexpected preferences before transport. The
page-URL image request preserves inherited `Referer`/`Origin` headers but does
not claim a retained DEX client or source-executed interceptor path. These are
offline assertions and do not claim live-site availability.

`ReaderView` resolves each source `ImageRequest` asynchronously. Supported
interpreted requests now carry an opaque UUID capability while the source actor
retains the exact DEX Request/tags and configured client in a bounded table.
Source-operation `await`/`awaitSuccess` and supported interpreted reader
requests (currently Baozi with its banner transform disabled) execute bounded,
registration-ordered application/network interceptor surfaces that preserve
Request identity, tags, cancellation, response bounds, and one VM instruction
budget. Page-URL profiles, including TuttoAnimeManga and Mangas-Origines.fr,
expose only a validated
URL/header projection to the ordinary reader image pipeline; they do not claim
retained DEX Request/client or source-interceptor execution. KamiCore validates
the public URL/header projection, separates hidden execution identities in its
cache, and receives only the bounded response. The GET-only interpreted reader
path can now observe one URLSession exchange at a time: application interceptors
run once, network interceptors run per response, and sanitized follow-ups share
the five-redirect and 64-step budgets. Baozi's direct-302 fixture proves its
redirect-domain tag rewrite, and the exact APK follows that rewritten
source-host URL to final image bytes. Its optional Bitmap banner crop remains
unsupported, so the production factory explicitly defaults `BAOZI_BANNER=0`.
General source-operation response sequences and non-GET redirect semantics
remain unproven. The production app has no UI/persistence path for the
remaining injected Baozi preference values.

## 7. Prior art (iOS)

- **Tachimanga** — native Swift Tachiyomi-style reader with its **own extension
  system** (JS-based sources, Tachiyomi-repo-compatible listing UX per its
  [extensions guide](https://tachimanga.app/help/guides/extensions_guide.html)) and
  Tachiyomi-compatible backup import. It does **not** execute DEX. (App Store.)
- **Aidoku** — own Swift-source extension format (.aix). No DEX.
- No known iOS app executes Mihon APK extensions. Kami's differentiator (and risk)
  is committing to Strategy A/E.

## 8. Bottom line

Unmodified-APK compatibility on iOS is **an effort-bounded problem, not a
feasibility problem**. The blockers, honestly categorized:

| Category | Status |
|---|---|
| DEX parsing/analysis | **Done** (this repo, pure Swift) |
| APK/manifest parsing | **Done** (pure Swift, incl. binary AXML) |
| Repo index compatibility | **Done** (JSON + proto) |
| Compatibility diagnostics | **Partial product surface**: exact sources capture the first typed stage-counted VM gap at the public VM boundary even when a nested host bridge catches/replaces it; unknown external fields fail closed unless explicitly modeled. `compat-audit gaps` emits a deterministic non-executing static/corpus priority report without paths or request data, and `compat-audit promote-gap` strictly converts the first canonical redacted runtime finding into a deterministic XCTest assertion seed. The current 13-artifact measurement run analyzed 13/13 with 0 errors, nine structural candidates, four stable-wrapper blockers, 511 unique unregistered external method surfaces, 0 omitted invocations, and 0 unsupported opcodes; app-facing export/share UX remains open |
| DEX execution | **Partial M1/M2 plus six pinned app-facing profiles work**: exact prototype dispatch, resolved reference/catch verification and runtime type checks, receiver-directed virtual entry and nested async selection under one instruction budget, maximally specific interface defaults, lexical class/interface super dispatch across parsed DEX graphs, class initialization, stable public source-wrapper routing across measured R8 layouts, pinned constructors/getters, and BatCave, Kawii Manga, MangaMelon, Baozi, TuttoAnimeManga, and Mangas-Origines.fr popular/search/latest/details/chapters/pages execute through bounded async response delivery and exact compatibility models; MangaMelon, Baozi, and Mangas-Origines.fr additionally prove exact static filters, while general downloaded-extension compatibility remains open |
| Kotlin/Java class library | **Measured tested subset**: core objects/strings, Kotlin ABI including query trimming/form encoding and bounded string/collection helpers, bounded lists/sets/maps and comparator sorting, structured coroutine lambdas, atomics/reflection, source filters with validated app-state reapplication, source-base constructors, bounded scalar preferences for Baozi, bounded OkHttp requests, a bounded application/network interceptor chain for source operations and source-scoped reader images, source-scoped async transport, response/body/Okio values including UTF-8/ByteString/Base64 request encoding, bounded Jsoup HTML/CSS including direct-child, sibling, attribute, `eachText`, and `:containsData` semantics, generated-serializer JSON encoding/decoding including defaults/longs/string memo objects, a measured locale/time-zone/Java-time subset, and reached `SManga`/`MangasPage`/`SChapter`/`SMangaUpdate`/`Page` models; dynamic filters, production preference UI/persistence, Android bitmap banner transforms, additional DOM APIs, and the long tail remain open |
| Cloudflare/WebView | Native WKWebView bridge design (see NETWORKING.md) |
| Backup import | Proto decoding done; zstd decompression pending |

## Sources

- https://github.com/mihonapp/tachiyomix (README, `library/`, `index/index.proto`)
- https://github.com/keiyoushi/extensions (`repo` branch: `index.min.json`)
- https://github.com/keiyoushi/extensions-source
- https://github.com/mihonapp/mihon (`extension/util/ExtensionLoader.kt`,
  `extension/api/ExtensionApi.kt`, `data/backup/models/Backup*.kt`, CHANGELOG.md)
- https://mihon.app/changelogs/v0.20.0
- https://tachimanga.app/help/guides/extensions_guide.html
