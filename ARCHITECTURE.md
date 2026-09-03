# Architecture

Kami is three layers with hard boundaries. Compatibility hacks live in
MihonCompatKit, never in the app.

```
┌──────────────────────────────────────────────┐
│ App (SwiftUI, iOS 17+)                       │
│  RootTab: Library/Updates/History/Browse/    │
│  Extensions · Reader · MangaDetail · Filters │
└──────────────┬───────────────────────────────┘
               │ KamiSource protocol (async)
┌──────────────┴───────────────────────────────┐
│ KamiCore                                     │
│  Models · LibraryStore (actor, SQLite)       │
│  ExtensionInstallationService                │
│  ExtensionAdmissionService                   │
│  ExtensionSourceFactory · SourceRegistry     │
│  SourceBrowseRequest                         │
│  ReaderSettings · ReaderImagePipeline        │
│  LibraryService                              │
│  Native sources: MangaDex                    │
└──────────────┬───────────────────────────────┘
               │ SMangaCompat/SChapterCompat/PageCompat
┌──────────────┴───────────────────────────────┐
│ MihonCompatKit (pure Swift, no Apple-only    │
│ frameworks — builds on iOS/macOS/Linux/      │
│ Windows)                                     │
│  APK: ZipArchive · Inflate · BinaryXML ·     │
│       APKSignatureVerifier                   │
│  Dex: DexFile + bounded M1 interpreter       │
│  Sources: structural plan + typed gap        │
│           reports + measured profiles        │
│  Repository: index.pb/index.min.json client  │
│  Backup: TachibkReader                       │
│  Analyzer: static gap/corpus audit + CLI     │
└──────────────────────────────────────────────┘
```

## Key decisions

- **`KamiSource` is the seam.** Native sources and the pinned BatCave, Kawii,
  MangaMelon, Baozi Manhua, TuttoAnimeManga, and Mangas-Origines.fr DEX-backed
  sources implement the same protocol; the registry hides which is which.
  Future profiles must preserve this boundary.
  The protocol mirrors tachiyomix semantics (popular/latest/search/details/
  chapters/pages + image requests with headers) so the bridge is 1:1.
- **Compat kit stays host-portable.** No UIKit/Combine/URLSession-only APIs
  without `#if canImport` guards. This is what allowed real verification on
  Windows during development and keeps the parsers unit-testable anywhere.
- **One database actor.** All persistence goes through `LibraryStore`
  (SQLite, WAL, versioned migrations). Views never see SQL.
- **Reader images cross one bounded seam.** After page-list resolution, the app
  asynchronously asks the source for one `ImageRequest` per page. The request's
  URL and headers enter the source-scoped `ReaderImagePipeline`, which reuses
  the compatibility transport's validation, redirect, response-stream, and
  cookie isolation rules. The actor deduplicates in-flight identities and owns
  a bounded compressed LRU. Apple-specific ImageIO downsampling and decoded-
  image viewport retention stay in the app layer; UIKit never enters KamiCore.
  Baozi's exact DEX `imageRequest(Page)` URL rewrite is therefore visible to
  the reader. Mangas-Origines.fr uses validated page-URL image requests with
  `Referer`/`Origin` headers and has no source-executed image-interceptor
  capability. Supported interpreted reader requests retain DEX `Request`
  identity/tags and the configured client inside the source actor, execute the
  bounded source-scoped interceptor chain, and share its cookie jar and VM
  budget. The GET-only reader seam observes redirects and follows sanitized
  rewritten locations; Baozi's real fixture proves the redirect-domain rewrite
  to final image bytes. Banner cropping and missing-image behavior are not
  proven through reader loads. `ReaderView` retries chapter
  loading through a structured `.task(id: reloadID)`; its disappearance cleanup
  increments the load generation so dismissal invalidates stale completions.
  Reader image fetching inherits the source's admitted transport policy,
  defaults to HTTPS-only, validates initial URL/headers before injected or
  production transport, and permits HTTP only through explicit source opt-in;
  redirect handling uses the same source-scoped policy. Ordinary page-URL
  profiles retain safe cross-origin CDN headers but strip source-derived
  credentials unless the image URL is same-origin.
- **Source-model values stay bounded at the bridge.** Manga-page and page-list
  outputs are capped at 2,048 entries, manga updates at 20,000 chapters, and
  `Page` URL/image-URL fields at 8 KiB. Metadata and source inputs have their
  own field limits; these are resource bounds rather than a claim of full
  tachiyomix model fidelity.
- **Downloaded sources require a persisted capability.** APK v1/v2/v3 signer
  verification runs before manifest/DEX work. `ExtensionAdmissionService`
  binds package, version, APK digest, source IDs, signer history, and the
  initial repository or explicit-user trust decision in SQLite. The only
  downloaded-source registry path requires the resulting internal-init
  capability; updates must preserve signing identity and cannot downgrade or
  replace bytes under the same version code.
- **Installation and restoration preserve the same trust chain.**
  `ExtensionInstallationService` stores APKs by content hash. A repository's
  normalized signing key authorizes a first install; a legacy store instead
  requires explicit confirmation of the already-verified certificate
  fingerprint. `ExtensionAdmissionService.restore` will issue a capability only
  for an enabled record whose on-disk hash, signature scheme, complete signer
  identity/history, user trust (when applicable), and manifest still match.
  `ExtensionSourceFactory` is the only capability consumer: it reads one
  bounded immutable buffer, repeats those checks on the bytes it will execute,
  preflights the profile's exact source-ID set before DEX construction, selects
  an exact measured profile, and postvalidates every constructed source ID
  against that set and the persisted admission. Measured profiles route stable
  public source API wrappers from either the generated entry class or its local
  superclass chain; startup failures and unmeasured profiles are disabled
  rather than run. The raw exact-profile constructors remain a deliberate
  built-in/test seam: they still reverify exact hash and signer, while the
  downloaded app path requires persisted admission and this factory.
- **Structural plans are descriptions, never capabilities.**
  `InterpretedExtensionPlanInspector` performs bounded, deterministic manifest,
  ZIP, and DEX discovery without executing code or establishing signer trust.
  It accepts only the currently measured single-source lib 1.6 shape, rejects
  factories, multidex and native `.so` entries, and reports stable blockers.
  The exact catalog consumes the same plan only after byte/signature/manifest
  authentication; `compat-audit` may inspect untrusted bytes but cannot admit
  or execute them. Automatic admission must remain a separate explicit gate.
- **Compatibility reports are evidence, never admission.** Runtime reports
  accept only typed VM linkage/opcode failures and store API identities plus an
  operation stage; arbitrary error descriptions and dynamic request/response
  values are ignored. The static audit never executes DEX and exposes only a
  sanitized plan status, DEX API identities, opcode counts, and package/version.
  An unregistered virtual/interface invocation is ranked as a possible shared
  host-surface gap, not claimed as a runtime failure. Neither report may create
  trust, catalog membership, source-ID authority, or registry access.
- **Untrusted code boundary.** Extension APKs are data until the interpreter
  runs them; even then they only reach iOS capabilities through explicit
  bridges (HTTP, bounded injected preferences, cookies, WebView) with budgets
  and isolation (EXTENSION_RUNTIME.md M1 guardrails). Production preference UI
  and persistence are not wired yet.
- **xcodegen, not a committed pbxproj.** `project.yml` is the source of
  truth; generated per-machine. Keeps diffs clean and remerges trivial.

## Exact interpreted profile boundary

The executable catalog is deliberately exact rather than heuristic. It
currently contains BatCave 1.6.9, Kawii Manga 1.6.1, MangaMelon 1.6.1,
Baozi Manhua 1.6.29, TuttoAnimeManga 1.6.10, and Mangas-Origines.fr 1.6.58.
Baozi is admitted only when
the APK's SHA-256
(`7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`), signer
fingerprint
(`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`),
manifest identity, and declared source ID (`5724751873601868259`) match the
profile and persisted admission capability. Its tested core scope is
popular/latest/search/details/chapters/pages, one static header plus four
static `Select` filters, bounded scalar preferences, and its interpreted
`imageRequest(Page)` URL rewrite. TuttoAnimeManga is admitted only when its
exact SHA-256 (`e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3`),
signer fingerprint
(`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`),
authenticated manifest, and source ID (`2102507871480604746`) match. Its
tested scope is metadata, popular/latest/text search, combined
details/chapters, pages, empty filters, inherited request headers, and the
default page image request. Mangas-Origines.fr exposes metadata identity
`Mangas-Origines.fr` / `fr` / `https://mangas-origines.fr` and is admitted only
when its package (`eu.kanade.tachiyomi.extension.fr.mangasoriginesfr`), version
`1.6.58` (code `58`), SHA-256
(`b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b`),
signer fingerprint
(`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`),
authenticated manifest, and source ID (`4803238581797687746`) match. Its
tested scope is metadata, seven static filters, ordered POST popular/latest/
search, details, chapters, pages, and page-URL image requests carrying
`Referer`/`Origin`; it has no source-executed image-interceptor capability.
The remaining 13 current lib 1.6 measurement artifacts are measurement
evidence, not automatic admission or a compatibility percentage. For the
downloaded path, the exact source-ID set is checked before DEX construction
and again after
profile construction; `SourceRegistry` removal is package-owner scoped, so
disabling one extension cannot remove another package's source ID.

The locked corpus currently contains 27 artifacts: 8 execution, 13 measurement,
and 6 AOSP conformance fixtures; 19 are current lib 1.6 artifacts. The current
measurement audit covers 13/13 artifacts and reports 9 structural candidates,
4 stable-wrapper blockers, 511 unique unregistered external method surfaces,
0 omitted invocations, and 0 unsupported opcodes. Komikcast (42 unresolved
surfaces) is only a prioritization signal for the next measured candidate.
Current Windows verification is 254/254 MihonCompatKit tests and 17/17 KamiCore
tests.

## Concurrency model
- UI: SwiftUI + `@MainActor` observable models.
- Sources: async/await throughout; every source call is cancellable.
- Persistence: actor-serialized SQLite.
- Reader images: one source-scoped pipeline actor owns transport tasks and
  compressed cache state; its `@MainActor` store coordinates visible loads,
  bounded prefetch, and lifecycle cancellation. ImageIO decoding runs in a
  detached user-initiated task before returning a bounded `UIImage`.
- Interpreter: the M1 runtime has a shared instruction budget and call-depth
  guard. Hierarchy-aware direct virtual source entry validates exact receiver
  identity, and one instruction budget remains shared across synchronous or
  async DEX re-entry from suspended host callbacks. Each app-facing interpreted
  source actor owns one mutable VM and uses a bounded cancellation-aware queue
  to prevent overlapping entry across suspend-method continuations.
