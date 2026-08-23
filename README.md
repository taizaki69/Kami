# Kami

A native iOS manga reader built around **real Mihon/Tachiyomi extension
ecosystem compatibility** — not a lookalike. Kami treats the ability to work
with actual, current extension APKs and extension stores as its core
engineering problem. See `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md` for the
verified ecosystem research and `docs/EXTENSION_COMPATIBILITY_MATRIX.md` for
measured status.

Created and maintained by [taizaki69](https://github.com/taizaki69).

**Honest status (2026-08-23):** the pure-Swift extension pipeline now covers
store indexes, APK download, bounded ZIP/DEFLATE and binary-manifest parsing,
validated DEX parsing, compatibility analysis, and an initial interpreter with
a bounded pre-execution geometry/control-flow, exception-table, register-bounds,
and typed register-dataflow verifier. The verifier now covers exact primitive
and constructor state, resolved reference assignability and joins, and resolved
catch types. Runtime dispatch resolves virtual overrides, lexical
`invoke-super`, and maximally specific interface defaults across the parsed DEX
class graph while leaving incomplete external graphs explicitly unresolved.
Pinned real-APK tests execute the Akuma, MangaDex, and BatCave entry
constructors plus BatCave's `getBaseUrl`, `getLang`, `getName`, and `getId`
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

A bounded APK verifier now authenticates v2, v3/v3.1, and a conservative v1
fallback, including signed content digests, X.509 signer keys, v3 certificate
rotation, and signature-stripping protection. KamiCore binds the verified
package/version/APK hash and signer history to persisted repository or explicit
user trust; downgrades, same-version byte replacement, unrelated signers, and
unadmitted source IDs are rejected before downloaded-source registration.
This closes the signer-admission security gate, but it is not a claim of broad
extension execution: dynamic APK-to-`KamiSource` construction, installation and
selection UI, filtered search, preferences, custom image-request behavior, and
much of the Kotlin/Java surface remain open (`docs/EXTENSION_RUNTIME.md`). The
shipping app still defaults to its native MangaDex source.

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

The compatibility kit and all 171 tests run on Windows with Swift 6.3
(`scripts/windows_dev_test.bat`). GitHub Actions is configured to run the pinned
real-APK suite on macOS, compiles both Simulator and unsigned device targets,
and publishes an unsigned IPA artifact. Exact-head commit `a902d06` passed
[Swift CI](https://github.com/taizaki69/Kami/actions/runs/32665870013),
[iOS Build](https://github.com/taizaki69/Kami/actions/runs/32665869921), and
[IPA Package](https://github.com/taizaki69/Kami/actions/runs/32665869959).
The `compat-audit` CLI produced the measured compatibility matrix from the
locked corpus.

## Non-goals / legality

Kami bundles no content and no sources' code. Extensions are user-installed
from third-party repositories at the user's direction.

Kami's original code is currently public but unlicensed: copyright is retained
by its creator and all rights are reserved while the long-term distribution
model is being decided. Public visibility does not make the project open
source. See [LICENSES.md](LICENSES.md) for the controlling notice and
third-party attributions.
