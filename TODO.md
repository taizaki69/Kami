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
- [x] `compat-audit` CLI (inspect/missing/index/methods) — run on 3 real APKs

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
      the pinned BatCave request path; bounded form/header/URL/cache/request/
      call models, Kotlin duration shims, async frame resumption, source-scoped
      transport, response/body/Okio values, bounded Jsoup document/element/CSS
      selectors (including modern direct-child and `:containsData` semantics),
      bounded Kotlin string/collection helpers, generated-serializer JSON decode,
      the reached Java-time subset, and `SManga`/`MangasPage`/`SChapter`/
      `SMangaUpdate` models now cover BatCave popular, text search, latest,
      details, and chapters; measured long tail remains
- [~] tachiyomix API bridge M3 (`HttpSource` → `KamiSource`) — the exact pinned
      BatCave 1.6.9 profile now implements the app-facing contract; general
      profile discovery, filters, preferences, and broader runtime coverage
      remain
- [x] First pinned real extension executing
      popular→search→details→chapters→pages — BatCave's unmodified locked APK
      now crosses deterministic transport and its real parsing/serialization
      paths for every proven operation, then exposes exact browse, details,
      chapter, page, and default image-request values through `KamiSource`.
      SHA-256 plus manifest/class identity gate construction, one source actor
      serializes the mutable VM, and `SourceRegistry` accepts the adapter;
      [#2](https://github.com/taizaki69/Kami/issues/2)
- [ ] Verify store/APK signing identity before enabling downloaded extension
      execution — [#3](https://github.com/taizaki69/Kami/issues/3)
- [ ] Privacy-safe unresolved API/opcode telemetry and exportable compatibility
      report — [#4](https://github.com/taizaki69/Kami/issues/4)
- [ ] zstd decompression for current-Mihon backups (schema work done)

## P1 — Daily driver

- [ ] Downloads manager (queue/pause/resume/persist across restarts)
- [ ] Library update scanner + grouping/notification summary
- [ ] Categories UI + management
- [ ] Migration flow (multi-source search + chapter matching)
- [ ] Backup/restore UI + import report
- [ ] Reader: RTL, webtoon continuous mode, prefetch, settings sheet
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
