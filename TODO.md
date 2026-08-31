# Kami — Task Tracker

Legend: `[ ]` not started · `[~]` in progress · `[x]` complete · `[!]` blocked

## P0 — Extension research & foundation

- [x] Verify current ecosystem: tachiyomix 1.6/1.7 API, manifest keys, index
      formats (proto + legacy JSON), backup protobuf schema —
      `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md`
- [x] Repository scaffold: SwiftPM packages + xcodegen spec + scripts
- [x] Bounded ZIP reader + DEFLATE/zlib/gzip decompressor (pure Swift), with
      size, structure, and checksum validation against real APKs
- [x] Binary Android XML (AXML) manifest parser — validated on real APK
- [x] DEX structural parser — validated on real APK (counts match reference)
- [x] Extension store client: `index.pb` + `index.min.json` + gzip unwrap +
      external-list indirection — validated against live Keiyoushi index
      (1372 extensions parsed)
- [x] Backup reader for legacy (zlib) `.tachibk` + proto schema decode
- [x] `compat-audit` CLI (inspect/missing/index/methods/disasm/opcodes/plan/gaps) —
      deterministic file and directory inspection, run on the locked corpus
- [x] SHA/URL-locked behavior-stratified current lib 1.6 measurement corpus —
      14 measurement-only Keiyoushi APKs under `Tests/corpus/measurement/`,
      alongside 7 execution and 6 AOSP conformance fixtures (27 total; 19
      current lib 1.6 artifacts). The remaining 14 measurement APKs analyze as
      10 structural candidates with 532 unique unregistered external method
      surfaces and zero unsupported opcodes. This is prioritization evidence,
      not a statistical sample or execution/admission proof. The local suite
      passes 234/234 with the corpus present.

## P0 — App foundation

- [x] Domain models + SQLite store with migrations + history/read-state
      preservation tests (run on macOS; code complete)
- [x] Native MangaDex source (popular/latest/search/details/chapters/pages)
- [x] SwiftUI app: Library / Browse / MangaDetail / Reader (paged) /
      Extensions (repo add via store client) / History / Updates placeholders
- [x] Reader progress + history persistence wired
- [x] GitHub Actions: portable tests, Simulator build, unsigned device build,
      and real unsigned IPA artifact

## P0 — End-to-end extension execution (the honest frontier)

- [~] DEX interpreter core M1 — frames/registers, core opcode families,
      objects/arrays/fields/invokes/exceptions, exact prototype dispatch,
      receiver-directed virtual/interface selection, maximally specific
      interface defaults, lexical class/interface `invoke-super` across parsed
      DEX graphs, one-time class initialization, invoke-kind validation, shared
      budgets, cancellation, a bounded structural verifier for instruction and
      payload geometry/control flow plus strict try/catch table decoding,
      register bounds, bounded exact primitive/constructor/reference dataflow,
      resolved `Throwable` catch validation, hierarchy-aware runtime casts and
      catches, and real-APK execution to an HTTP boundary; broader external
      hierarchy resolution, remaining opcodes, and differential conformance are
      tracked in
      [#1](https://github.com/taizaki69/Kami/issues/1)
- [~] Kotlin/Java class library M2 — Object/String/StringBuilder, core Kotlin
      ABI, bounded collections, atomics, reflection, and Mihon filters cover
      the pinned BatCave, Kawii, MangaMelon, Baozi, and TuttoAnimeManga request paths; bounded form/header/URL/cache/request/
      call models, Kotlin duration shims, async frame resumption, source-scoped
      transport, response/body/Okio values, bounded Jsoup document/element/CSS
      selectors (including modern direct-child and `:containsData` semantics),
      bounded Kotlin string/collection helpers, generated-serializer JSON decode,
      the reached Java-time subset, and `SManga`/`MangasPage`/`SChapter`/
      `SMangaUpdate` models now cover BatCave popular, text search, latest,
      details, and chapters, while Kawii also proves nullable/boolean JSON,
      bounded `HttpUrl.Builder`, custom source headers, Kotlin `Instant`, and
      stable-wrapper execution; MangaMelon additionally proves exact static
      filters, JSON defaults/longs/memo, structured coroutine lambdas,
      comparator sorting, and UTF-8/ByteString/Base64 form data; Baozi
      additionally proves its bounded scalar SharedPreferences and interpreted
      image-request path; measured long
      tail remains a static prioritization target in the locked measurement set
- [~] tachiyomix API bridge M3 (`HttpSource` → `KamiSource`) — the exact pinned
      BatCave 1.6.9, Kawii Manga 1.6.1, MangaMelon 1.6.1, Baozi Manhua
      1.6.29, and TuttoAnimeManga 1.6.10 profiles implement the measured app-facing contract through stable
      public wrappers; static
      `Sort`/`Select` filters, Baozi's bounded scalar preferences, and Baozi's
      interpreted custom image request are proven; dynamic/network-backed
      filters, production preference UI/persistence, reader-image interceptor
      execution, and broader runtime coverage remain open
- [x] First pinned real extension executing
      popular→search→details→chapters→pages — BatCave's unmodified locked APK
      now crosses deterministic transport and its real parsing/serialization
      paths for every proven operation, then exposes exact browse, details,
      chapter, page, and default image-request values through `KamiSource`.
      SHA-256 plus manifest/class identity gate construction, one source actor
      serializes the mutable VM, and `SourceRegistry` accepts the adapter;
      [#2](https://github.com/taizaki69/Kami/issues/2)
- [x] Verify store/APK signing identity before enabling downloaded extension
      execution — bounded v1/v2/v3 verification, exact Mihon fingerprints,
      persisted initial trust, rotation-aware updates, and capability-gated
      registry admission — [#3](https://github.com/taizaki69/Kami/issues/3)
- [x] Trusted extension installation/selection UI and APK-to-`KamiSource`
      construction through the persisted admission gate — repositories and
      content-addressed APKs persist, repository keys or explicit legacy-store
      signer confirmation establish trust, every startup re-authenticates the
      exact bytes, and enabled downloaded sources appear in Browse. The factory
      intentionally supports only exact measured profiles today. Its exact
      profile source-ID set is preflighted before DEX construction and the
      constructed source IDs are postvalidated; registry removal is scoped to
      the owning package. The raw exact-profile constructors remain a deliberate
      built-in/test seam and still reverify the exact hash and signer; downloaded
      app execution must use persisted admission plus the sole factory.
- [x] Generic source-filter Browse UI: transactional editing for every
      app-facing Mihon filter case, source-default preservation for text
      searches, blank-query filtered search, reset/clear, pull-to-refresh, and
      stale-response-safe pagination
- [x] Stable interpreted wrapper routing and a second current extension:
      app-facing calls use measured public `KeiSource` wrappers from either a
      local superclass or an R8-merged entry class, and Kawii Manga 1.6.1 runs
      popular→search→details→chapters→pages from its locked APK with its custom
      request header
- [x] Authenticated profile-surface discovery and a third current extension:
      stable metadata/wrappers are derived from exact admitted APKs without
      R8-private worker mappings; MangaMelon 1.6.1 proves full core operations
      and static filtered search while preserving admission/source-ID gates
- [x] Bounded structural execution-plan inspection: shared exact-runtime/CLI
      discovery checks manifest identity, supported lib version, single-source
      and single-DEX shape, absence of native `.so` entries, entry placement,
      and stable public wrappers without executing or admitting unknown APKs;
      the five exact profiles and all 14 remaining measurement APKs produce
      deterministic results: 10 measurement candidates, 532 unique
      unregistered surfaces, zero unsupported opcodes, and four stable-wrapper
      blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC); legacy lib 1.4
      specimens remain explicit blockers
- [x] Expand the exact catalog with a fourth current extension — Baozi Manhua
      1.6.29 is admitted by exact SHA-256, signer, manifest, source-ID, and
      structural gates. Deterministic fake-transport tests prove its
      popular/latest/search/details/chapters/pages path, exact static filters,
      bounded scalar preferences, a valid non-default filter state, and DEX
      `imageRequest` URL rewrite.
- [x] Expand the exact catalog with a fifth current extension — TuttoAnimeManga
      1.6.10 is admitted by exact SHA-256, signer, manifest, source-ID, and
      structural gates. Deterministic real-APK tests prove its metadata,
      popular/latest/search/details/chapters/pages path, empty filter schema,
      inherited request headers, latest sorting/ten-result cap, default image
      request, and rejection of unsupported filters/preferences before transport.
- [x] Execute source-defined OkHttp application and network interceptors for
      source operations through a bounded source-scoped chain. It preserves
      exact DEX `Request` identity/tags and registration/unwind order, enforces
      32 interceptors, 64 interceptor/terminal steps, depth 32, and one
      `proceed` per chain object, charges replacement bytes/headers to the
      transport policy, checks cancellation at every edge, and shares the
      parent VM instruction budget. Baozi's real core operations traverse the
      chain and its finite rate limiter.
- [x] Add a source-scoped reader-image execution seam that retains DEX
      `Request` identity/tags and deliberately invokes the interceptor chain.
      Supported GET reader images observe bounded intermediate redirects and
      follow sanitized locations; Baozi's real fixture proves redirect-domain
      rewriting to final bytes. Banner cropping remains unsupported until a
      bounded portable pixel/JPEG implementation exists; missing-image behavior
      is still unproven in reader image loads.
- [x] Carry each source's explicit insecure-HTTP policy into reader image
      fetching: pinned sources retain the factory policy, `ReaderView` passes
      it into `ReaderImagePipeline`, initial URL/headers are validated before
      injected or production transport, HTTPS is the default, and HTTP requires
      explicit source opt-in. Redirects use the same source-scoped policy.
- [ ] On reader-image retry, regenerate and revalidate the source's
      `ImageRequest`, and define request/header expiry and credential-refresh
      semantics. The current retry task reuses the request resolved during page
      loading.
- [ ] Harden regex execution with a bounded or demonstrably linear-time
      matcher (or an explicit match-step budget). Current `NSRegularExpression`
      use is bounded by pattern/input/output sizes but not by worst-case match
      time.
- [ ] Wire production preference UI and persistence for the bounded
      `InterpretedExtensionPreferences` model; current app construction uses
      profile defaults.
- [~] Privacy-safe compatibility telemetry — typed runtime class/method/field/
      opcode failures are stage-deduplicated without arbitrary error strings;
      the first typed gap is retained below caught host-bridge fallbacks,
      external fields fail closed unless explicitly modeled, `compat-audit
      gaps` emits a deterministic path-free static/corpus priority report, and
      `compat-audit promote-gap` emits a deterministic focused XCTest seed.
      App-facing user-selected export/share remains —
      [#4](https://github.com/taizaki69/Kami/issues/4)
- [ ] zstd decompression for current-Mihon backups (schema work done)

## P1 — Daily driver

- [ ] Downloads manager (queue/pause/resume/persist across restarts)
- [ ] Library update scanner + grouping/notification summary
- [ ] Categories UI + management
- [ ] Migration flow (multi-source search + chapter matching)
- [ ] Backup/restore UI + import report
- [x] Reader foundation: persistent LTR/RTL/webtoon modes, direction-aware tap
      zones, paged zoom/pan, settings, keep-awake, bounded header-aware image
      loading/prefetch, off-main downsampling, retry, and progress/history
- [ ] Reader completion: previous/next chapter flow, configurable tap actions,
      fit/crop/brightness controls, runtime-to-reader cookie continuity,
      memory-pressure purging, and download/disk-cache integration
- [ ] Cloudflare WKWebView bridge + cookie sync (M4)
- [ ] Global search across enabled sources

## P2 — Polish

- [ ] Local CBZ/ZIP source
- [ ] Diagnostics screen + exportable logs (redacted)
- [ ] iPad dual-page reader
- [ ] Performance pass vs docs targets (launch, 5k-library, webtoon 500p)

## External validation remaining

- [ ] Install and smoke-test a signed build on a physical iPhone/iPad using
      user-owned Apple credentials (CI intentionally produces an unsigned IPA)
