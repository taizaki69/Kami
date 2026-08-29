# Kami

A native iOS manga reader built around **real Mihon/Tachiyomi extension
ecosystem compatibility** — not a lookalike. Kami treats the ability to work
with actual, current extension APKs and extension stores as its core
engineering problem. See `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md` for the
verified ecosystem research and `docs/EXTENSION_COMPATIBILITY_MATRIX.md` for
measured status.

Created and maintained by [taizaki69](https://github.com/taizaki69).

**Honest status (2026-08-29):** the pure-Swift extension pipeline now covers
store indexes, APK download, bounded ZIP/DEFLATE and binary-manifest parsing,
validated DEX parsing, compatibility analysis, and an initial interpreter with
a bounded pre-execution geometry/control-flow, exception-table, register-bounds,
and typed register-dataflow verifier. The verifier now covers exact primitive
and constructor state, resolved reference assignability and joins, and resolved
catch types. Runtime dispatch resolves virtual overrides, lexical
`invoke-super`, and maximally specific interface defaults across the parsed DEX
class graph while leaving incomplete external graphs explicitly unresolved.
Pinned real-APK tests execute the Akuma, MangaDex, BatCave, Kawii Manga, and
MangaMelon entry constructors plus BatCave's `getBaseUrl`, `getLang`, `getName`, and `getId`
methods. BatCave's real popular-manga path now runs through Kotlin class
initialization, filters, collections, iteration, coroutine setup, and a bounded
OkHttp model. It constructs the exact BatCave popular POST request, crosses an
injected source-scoped async transport, resumes nested DEX frames, and exposes
bounded `Response`, `ResponseBody`, and `BufferedSource` values. A bounded
SwiftSoup-backed Jsoup bridge now runs BatCave's production CSS selectors and
the real APK returns an exact `MangasPage` from deterministic response HTML,
including relative-URL resolution and pagination. Its real text-search branch
also trims and Java-form-encodes a page-2 query, preserves the source's cache
policy, and returns the parsed result. The public latest-updates path likewise
builds its cached page GET and returns a parsed page. The real manga-details
worker now returns URL, title, thumbnail, publisher/year description, author,
artist, genres, and status using modern Jsoup direct-child selector semantics.
Its combined manga-update worker also extracts `window.__DATA__`, drives the
APK's generated kotlinx serializers through a bounded generic JSON decoder,
and returns exact `SChapter` values plus `SMangaUpdate`, including fractional
chapter numbers, source-local dates, invalid-date fallback, and xhash URLs.
Its real page-list worker now executes generated JSON request encoding, sends
the exact reader POST, decodes the generated response DTOs from a bounded Okio
source, normalizes image URLs, and returns exact `PageCompat` values. Malformed
page JSON, invalid UTF-8, and wrong response types are typed failures.
A separate real-APK regression proves non-2xx responses become Mihon's
`HttpException`. `PinnedInterpretedSource` now verifies the exact BatCave APK's
SHA-256, cryptographic APK v2 signer identity, manifest identity, and entry
class before exposing all of those proven operations plus default reader image
requests through the same `KamiSource` contract as native sources. One actor
owns and serializes each mutable VM and transport across suspension, and
KamiCore can register it without source-kind branches.

The runtime now routes app-facing calls through stable public `KeiSource`
wrappers whether R8 leaves them on a local superclass or vertically merges them
into the generated entry class. A second current profile, Kawii Manga 1.6.1,
uses that path end to end: its exact popular/latest/search/detail+chapter/page
JSON operations run from the locked unmodified APK, its dynamic `HttpUrl`
queries are encoded and bounded, its custom `x-app-key` header reaches every
request, and nullable/boolean serialization, `distinct`, character-delimiter
substring helpers, and Kotlin `Instant` conversion execute through the
deny-by-default host bridge.

A third current profile, MangaMelon 1.6.1, adds the first measured app-facing
filter round trip. Kami derives its `Sort` and `Select` schema from the exact
authenticated APK, validates app-edited state against that immutable shape,
and passes the original DEX filter instances back through the stable search
wrapper. Its full popular/latest/filtered-search/details/chapters/pages path
proves default-inclusive generated JSON encoding, bounded UTF-8/Okio/Base64
form bodies, structured coroutine lambdas, long decoding, stable comparator
sorting, string-valued chapter memo JSON, and deterministic page ordering.

The corpus now also locks 16 current lib 1.6 Keiyoushi APKs under
`Tests/corpus/measurement/` for measurement only. Together with the five
existing execution fixtures and six AOSP apksig conformance fixtures, the lock
contains 27 artifacts; 19 are current lib 1.6 artifacts (three existing
execution fixtures plus the 16 measurement fixtures). The measurement set is
behavior-stratified, not a statistical sample, and occupies 1.24 MB
(1,242,086 bytes). A deterministic static run analyzed all 16 measurement APKs
with zero errors, found 12 structural candidates and four stable-wrapper
blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC), and reported 626 unique
unregistered external method surfaces with zero unsupported opcodes. These
artifacts are parsed, signature-verified for parser conformance, and statically
audited only: membership never grants signer trust, admission, installation, or
execution. Baozi Manhua 1.6.29 is the selected next fourth-profile target
because it is current, catalog-labeled `safe`, and a structural-plan candidate
that exercises preferences and a custom `imageRequest`; no execution is claimed
for it yet.

A bounded APK verifier now authenticates v2, v3/v3.1, and a conservative v1
fallback, including signed content digests, X.509 signer keys, v3 certificate
rotation, and signature-stripping protection. KamiCore binds the verified
package/version/APK hash and signer history to persisted repository or explicit
user trust; downgrades, same-version byte replacement, unrelated signers, and
unadmitted source IDs are rejected before downloaded-source registration.

The app now completes that trust path: it persists extension repositories and
content-addressed APKs, automatically uses a repository's pinned signing key,
asks the user to confirm a verified certificate fingerprint for legacy stores,
supports install/update and enable/disable controls, and restores enabled
extensions after rechecking the stored hash, signature, signer continuity, and
manifest. The only APK-to-`KamiSource` factory consumes that restored admission,
re-authenticates the exact immutable buffer it executes, and refuses undeclared
source IDs or unsupported profiles. Enabled downloaded sources appear beside
the native MangaDex source in Browse.

The first reusable profile-discovery seam is now shared by that exact runtime
and `compat-audit plan`. Without executing DEX or granting trust, the bounded
inspector either produces a deterministic lib 1.6 structural plan or explicit
blockers for manifest identity, factories, DEX layout, native `.so` entries,
entry-class placement, and stable public wrappers. The three current profiles
produce the same plans on repeated inspection; the two legacy lib 1.4 corpus
artifacts are reported unsupported instead of guessed. A structural plan is
only a description: it is not signer authentication, catalog admission, or
proof that an extension's operations will execute.

Compatibility failures now have a privacy-safe measurement seam. Exact pinned
sources record only typed unresolved class/method/field and unsupported-opcode
errors, deduplicated by app-facing operation stage; arbitrary error strings,
HTTP failures, request values, and parser data never enter the report.
`compat-audit gaps` separately performs a bounded, non-executing scan of one APK
or a directory, ranks external method invocations that are not exactly
registered on the current host bridge, aggregates unsupported opcodes and plan
blockers, and emits deterministic artifact ordinals instead of local paths or
filenames. Those static method findings are prioritization signals—not proof
that a virtual/interface call will fail, signer trust, admission, or execution
compatibility.

Browse now renders the complete app-facing Mihon filter hierarchy: headers,
separators, selects, text fields, checkboxes, tri-state controls, nested groups,
and sortable fields. Editing is transactional, Apply can run a filter-only
search with a blank query, and Clear exits filter-only mode. Every text search
passes the source's full filter schema with either default or user-edited
state. Result resets and pagination also ignore stale responses instead of
mixing results from superseded requests.

The native reader now has persistent LTR, RTL, and continuous webtoon modes,
direction-aware tap zones, paged pinch/double-tap zoom, configurable background,
keep-screen-awake, retry, progress/history persistence, and bounded prefetch.
Page bytes no longer use `AsyncImage`: a source-scoped actor forwards the exact
`ImageRequest` headers through the hardened streaming transport, deduplicates
loads, keeps a bounded compressed LRU, and feeds off-main ImageIO downsampling.
Decoded paged images are limited to the current page and its neighbors, while
webtoon pages release decoded images outside the lazy viewport. Runtime-to-
reader cookie continuity, dual-page spreads, and physical-device performance
profiling remain open; see `docs/READER.md`.

This is still not a claim of broad extension execution: Kami can identify a
bounded structural candidate, but the runtime profile catalog currently
recognizes only the exact measured BatCave 1.6.9, Kawii Manga 1.6.1, and
MangaMelon 1.6.1 builds. The broader 16-APK current-lib-1.6 corpus is a
non-executing measurement set, not an admitted profile catalog. Automatic
profile admission beyond that exact catalog, dynamic/network-backed filter
lists, preferences, a measured extension-defined custom image-request override,
and much of the Kotlin/Java surface remain open (`docs/EXTENSION_RUNTIME.md`).
Kami starts
with native MangaDex and can additionally restore a supported, authenticated
downloaded source.

## Layout

```
App/                    SwiftUI app (iOS 17+)
Packages/
  MihonCompatKit/       Extension compatibility: APK/ZIP, AXML, DEX,
                        store index (index.pb/index.min.json), backup reader,
                        analyzer + compat-audit CLI
  KamiCore/             Domain models, SQLite store, native sources, services
scripts/                bootstrap / build / test / package_ipa / fetch_corpus
docs/                   analysis, matrix, runtime plan, per-area docs
```

## Quick start (macOS)

```bash
bash scripts/bootstrap.sh        # xcodegen + project + optional corpus
bash scripts/build.sh            # simulator build
bash scripts/test.sh             # package tests + app tests
bash scripts/package_ipa.sh      # dist/Kami.ipa (unsigned; sign at install)
```

Requirements: Xcode 15+, xcodegen. Details: `BUILDING.md`, `docs/IPA_BUILD.md`.

Moving development to another computer? Start with [HANDOFF.md](HANDOFF.md);
it records the known-good SHA, restore commands, verification evidence,
security boundaries, and the recommended next implementation sequence.

## Verified on Windows too

The compatibility kit and all 192 tests run locally on Windows with Swift 6.3,
including the three corpus-lock regressions, together with 12 portable KamiCore
tests (`scripts/windows_dev_test.bat`). Exact corpus head `a376064` passes
[Swift CI](https://github.com/taizaki69/Kami/actions/runs/33279595763) with all
27 fixtures, 192 MihonCompatKit tests, 23 KamiCore tests, and the optimized CLI;
[iOS Build](https://github.com/taizaki69/Kami/actions/runs/33279595816) for both
simulator and unsigned device; and
[IPA Package](https://github.com/taizaki69/Kami/actions/runs/33279595746) with
the uploaded unsigned IPA.
The `compat-audit` CLI produces the measured compatibility matrix,
deterministic per-APK structural-plan blockers, and a redacted static
gap/corpus report from the locked corpus.

## Non-goals / legality

Kami's iOS app target bundles no manga content or third-party extension code.
Extensions are user-installed from third-party repositories at the user's
direction. The repository separately vendors hash-pinned third-party APKs under
`Tests/corpus/` solely as test fixtures; they are not app resources or shipped
with the app.

Kami's original code is currently public but unlicensed: copyright is retained
by its creator and all rights are reserved while the long-term distribution
model is being decided. Public visibility does not make the project open
source. See [LICENSES.md](LICENSES.md) for the controlling notice and
third-party attributions.
