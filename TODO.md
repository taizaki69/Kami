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
      16 measurement-only Keiyoushi APKs under `Tests/corpus/measurement/`,
      alongside 5 execution and 6 AOSP conformance fixtures (27 total; 19
      current lib 1.6 artifacts); 16/16 static analyses complete with 0 errors,
      12 structural candidates, 4 stable-wrapper blockers, 626 unique
      unregistered external method surfaces, and 0 unsupported opcodes. The
      1.24 MB set is prioritization evidence, not a statistical sample or
      execution/admission proof. Three `CorpusLockTests` bring the local
      MihonCompatKit verification to 192/192.

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
      the pinned BatCave, Kawii, and MangaMelon request paths; bounded form/header/URL/cache/request/
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
      comparator sorting, and UTF-8/ByteString/Base64 form data; measured long
      tail remains a static prioritization target in the locked measurement set
- [~] tachiyomix API bridge M3 (`HttpSource` → `KamiSource`) — the exact pinned
      BatCave 1.6.9, Kawii Manga 1.6.1, and MangaMelon 1.6.1 profiles implement
      the app-facing contract through stable public wrappers; static
      `Sort`/`Select` filters are proven while dynamic filters, preferences,
      custom image requests, and broader runtime coverage remain open
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
      intentionally supports only exact measured profiles today.
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
      the three execution profiles and all 16 measurement APKs produce
      deterministic results: 12 measurement candidates and four stable-wrapper
      blockers (Komga, MangaPlus, NHentai.xxx, and XCOMIC); legacy lib 1.4
      specimens remain explicit blockers
- [ ] Expand beyond the exact three-profile catalog with a fourth current
      extension — Baozi Manhua 1.6.29 is selected as the next target because it
      is current, catalog-labeled `safe`, and a structural-plan candidate that exercises
      preferences plus a custom `imageRequest`; measurement membership alone
      does not authorize execution
- [~] Privacy-safe compatibility telemetry — typed runtime class/method/field/
      opcode failures are stage-deduplicated without arbitrary error strings,
      and `compat-audit gaps` emits a deterministic path-free static/corpus
      priority report. App-facing file export, first-gap capture below caught
      DEX errors, field/bridge coverage, and fixed-gap-to-regression promotion
      tooling remain — [#4](https://github.com/taizaki69/Kami/issues/4)
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
