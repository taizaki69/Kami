# Kami — Task Tracker

Legend: `[ ]` not started · `[~]` in progress · `[x]` complete · `[!]` blocked


## Active continuation — 2026-10-06

The full native-reader and compatibility objective remains active. The current
continuation extends reviewed, additive source migration with manual one-to-one
chapter pairing, bounded local chapter search and current match coverage.
Occupied destinations require explicit unpairing; changed choices invalidate
review acknowledgement. It follows unique-number suggestions, selected-source
search and atomic read/bookmark/category transfer. The original and its files,
history and page positions remain intact. Replace/remove mode and physical
migration interaction remain open; see [migration](docs/SOURCE_MIGRATION.md).
It follows persistent source/language selection for Browse and global
search, with explicit all/none semantics, remembered unavailable identities,
reviewed edits and revocable search snapshots. It follows bounded local
compatibility diagnostics and user-selected
Files export, with typed-symbol validation and explicit loss accounting. It
follows global search across enabled sources, with progressive groups,
bounded concurrent queries, cancellation drainage and guarded source navigation.
It follows tiled drawing and aspect-aware long-page resolution, plus
hosted simulator rendering regressions. The bounded source bitmap still decodes
as a whole; region decoding and device profiling remain open. It follows reader
memory warnings with cache purging, cancelable prefetch ownership, viewport-based
decoded residency and reduced visible bitmaps without re-fetching them, and persistent reader tap actions,
fitting, reversible border cropping, brightness and shared display ownership,
and the reviewed Mihon import for the measured English MangaDex
identity and exact paths, native atomic merge and store-issued contexts.
It builds on durable FoolSlide website identity, atomic reader state with database-issued reading targets, bounded
native export to Files, Mihon gzip/raw backup decoding, offline downloads,
updates, History resume and revocable source registrations. Native restore is
available; the measured Mihon subset now imports with explicit coverage and
exclusion review. Broader source adapters remain pending.
See [native backup verification](docs/VERIFICATION-2026-10-04-NATIVE-BACKUPS.md),
[reading-state design](docs/READING_STATE.md),
[Mihon decoder verification](docs/VERIFICATION-2026-10-04.md) and
[earlier verification](docs/VERIFICATION-2026-10-03.md) for actual evidence.
Completed items below retain some historical checkpoint counts; those counts
must not be used as evidence for the current commit.

- [x] Finish and verify exact FoolSlide Customizable 1.6.6 promotion, including
      configured factory admission, fail-before-transport boundaries, bounded
      mutable HTML and the reached date-builder semantics.
- [x] Verify category persistence and Apple compilation at `ecc97bc` (PR #10).
      Physical-device interaction remains a separate verification task.
- [x] Reconcile execution/measurement roles for EternalMangas, DocTruyen3Q and
      FoolSlide without changing their APK hashes or granting new trust.
- [x] Integrate persistent production settings for FoolSlide 1.6.6: authenticated
      schema, typed SQLite document, stale-save rejection, explicit enablement,
      source/image revocation and transactional source-result persistence.
      Verified at `0ae9c4d` (PR #11), including Linux/macOS SQLite tests,
      simulator/device compilation and unsigned IPA packaging.
- [ ] Extend editable settings only after proving each additional profile's
      value domains and execution effects; Baozi keeps its safe banner default.
- [x] Implement manual library scanning, durable chapter discoveries, progress,
      cancellation, finite per-manga outcomes and paginated Updates UI; resume
      History/Updates from current persisted reading state. The SQLite and
      coordination suites pass locally; the implementation PR records Apple
      verification for its exact commit, separately from interaction testing.
- [ ] Add scheduled background updates with explicit product controls.
- [x] Implement the foreground downloads manager: durable queue, pause/cancel,
      fresh retry, bounded file storage, offline reader and deferred deletion.
      Local fixtures pass; exact-commit Apple CI is recorded on its PR,
      separately from physical-device interaction and performance.
- [ ] Continue migration/backup UI and remaining reader controls,
      without treating a passing compatibility suite as completion of the app.
- [x] Integrate persistent reader tap actions, whole-page/width/height fitting,
      bounded panning and reversible uniform-border cropping in online/offline
      readers. Keep a controls recovery button when custom tap actions hide UI.
- [x] Add a brightness override and shared keep-awake/display ownership;
      preserve other readers and observed system changes, release on inactivity
      and use the actual window screen. Apple supports brightness only on the
      main display. See [reader controls](docs/READER.md) for validation limits.
- [x] Handle iOS memory warnings in online/offline readers: purge compressed
      cache, disable prefetch for the open reader, cancel unneeded flights,
      release offscreen pixels and reduce visible bitmaps without another fetch.
      Retain measured webtoon geometry and existing crop/zoom/progress.
- [ ] Profile memory-warning delivery, scroll stability and peak memory on an
      Apple device and test 500-page chapters. A bounded
      thumbnail or pure 500-index residency test does not establish performance.
- [x] Draw reader pages with asynchronous image tiles and retain more detail
      in long pages using explicit normal/pressure pixel budgets. Add native
      pixel/seam tests and hosted UIKit rendering/scroll/replacement tests.
- [ ] Add region decoding or a bounded tile-file pipeline so very large source
      pages can retain detail without holding a whole decoded bitmap. Tiled
      drawing alone does not complete that requirement or establish peak memory.
- [x] Verify strict gzip/raw backup decoding against real Kotlin serializer
      output; retain library data and explicit unsupported-field coverage.
- [x] Add versioned native library export: strict bounded JSON, a complete
      transactional snapshot and cancellable Files export with scope/counts.
      Includes hidden chapters, full history/duration and discovery state.
- [x] Commit reader progress/history/read state atomically, reject stale or
      rebound reading targets and show persistence errors; integrate offline
      leases and manual read actions with captured targets and verify them.
      PR #16 at b122ee9 passes Linux/macOS tests, simulator/device and IPA CI.
- [x] Add durable Foo content binding with exact URL identity, independent
      configuration CAS and bounded one-time migration inference.
      PR #17 at b15344d passes Linux/macOS tests, simulator/device and IPA CI.
- [x] Preserve byte-distinct chapter URLs during replacement, disappearance
      and discovery; retain separate reading state, history and download jobs.
      Updates IDs/cursors also compare exact bytes. Five reproduced regressions
      and all 296 Core/SQLite tests pass locally; the implementation PR records
      exact-commit Apple verification separately.
- [x] Integrate shared synchronous operation admission across scenes, with
      reader/run/prompt lifetime ownership, cancellation drainage, old-route
      generation rejection and publication invalidation. Local checks pass
      327 Core/SQLite, 112 portable Core and 371 Compat; the implementation PR
      records exact-head Apple compilation and artifact evidence separately.
- [ ] Exercise multiple windows, suspended providers and reader cleanup on an
      Apple device/simulator; package ordering tests do not prove UI interaction.
- [x] Require an opaque store/epoch context for category, membership and source
      result writes, captured with values before scheduling and retained through
      provider suspension. Reject stale, foreign and malformed generations inside
      write transactions; retain strict rollback and cancellation behavior.
      Local checks pass 310 Core/SQLite, 97 portable Core and 371 Compat tests.
      The implementation PR records exact-head Apple checks separately.
- [x] Add immutable native restore preview and atomic conservative merge, with
      stale-plan rejection, exact identities, source conflicts and Files review.
      Preserve downloads, metadata, trust and settings; publish a fresh epoch
      and scene generation only after commit. See [native restore](docs/NATIVE_BACKUPS.md).
- [x] Adapt the measured Mihon MangaDex English ID and exact URL forms to native
      identities; show unsupported-field and source-mapping coverage before
      commit. Unsupported identities are explicitly excluded, never routed to a
      native source. See [Mihon import](docs/MIHON_IMPORT.md).
- [ ] Add evidence-backed adapters for further sources/languages and supported
      URL forms; retain original identities and honest exclusion coverage.
- [ ] Verify Files providers, cancellation, large-library memory use and
      restored-reader navigation on an Apple device; compilation is separate evidence.

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
- [~] Bounded gzip/raw `.tachibk` reader with verified Mihon defaults and an
      unsupported-field report. The former legacy-zlib/current-zstd claim was
      incorrect; see `docs/BACKUP_COMPATIBILITY.md`. This is a library DTO
      decoder, not a completed backup restore flow.
- [x] `compat-audit` CLI (inspect/missing/index/methods/disasm/opcodes/plan/gaps) —
      deterministic file and directory inspection, run on the locked corpus
- [x] SHA/URL-locked behavior-stratified current lib 1.6 measurement corpus —
      11 measurement-only Keiyoushi APKs under `Tests/corpus/measurement/`,
      alongside 10 execution and 6 AOSP conformance fixtures (27 total; 19
      current lib 1.6 artifacts). The current measurement audit covers all 11/11
      remaining measurement APKs: 7 structural candidates with 432 unique
      unregistered external method surfaces, zero omitted invocations, and zero
      unsupported opcodes. This is prioritization evidence, not a statistical
      sample or execution/admission proof. Current Windows verification through
      the checked-in helper passes 262/262 MihonCompatKit and 19/19 portable
      KamiCore tests; historical test counts remain documented in the
      compatibility-matrix evidence. Komikcast and Yomu Comics are now exact
      execution profiles rather than measurement candidates.

## P0 — App foundation

- [x] Domain models + SQLite store with migrations + history/read-state
      preservation tests (run on macOS; code complete)
- [x] Native MangaDex source (popular/latest/search/details/chapters/pages)
- [x] SwiftUI app: Library / Browse / MangaDetail / Reader (paged) /
      Extensions (repo add via store client); History resume and manual
      Updates are implemented in the active continuation above
- [x] Reader progress + history persistence wired
- [x] GitHub Actions: portable tests, Simulator build, unsigned device build,
      and real unsigned IPA artifact

## P0 — End-to-end extension execution (the honest frontier)

- [~] DEX interpreter core M1 — frames/registers, core opcode families,
      objects/arrays/fields/invokes/exceptions, exact prototype dispatch,
      hierarchy-aware direct virtual source entry with exact receiver identity
      validation, receiver-directed virtual/interface selection, maximally specific
      interface defaults, lexical class/interface `invoke-super` across parsed
      DEX graphs, one-time class initialization, invoke-kind validation, shared
      budgets, one instruction budget across synchronous or async DEX re-entry
      from suspended host callbacks, cancellation, a bounded structural verifier for instruction and
      payload geometry/control flow plus strict try/catch table decoding,
      register bounds, bounded exact primitive/constructor/reference dataflow,
      resolved `Throwable` catch validation, hierarchy-aware runtime casts and
      catches, and real-APK execution to an HTTP boundary; broader external
      hierarchy resolution, remaining opcodes, and differential conformance are
      tracked in
      [#1](https://github.com/taizaki69/Kami/issues/1)
- [~] Kotlin/Java class library M2 — Object/String/StringBuilder, core Kotlin
      ABI, bounded collections, atomics, reflection, and Mihon filters cover
      the pinned BatCave, Kawii, MangaMelon, Baozi, TuttoAnimeManga,
      Mangas-Origines.fr, Komikcast/VoraToon, and Yomu request paths; bounded
      form/header/URL/cache/request/
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
      image-request path; Mangas-Origines.fr additionally proves seven static
      filters, ordered POST popular/latest/search, details/chapters/pages, and
      page-URL image requests with `Referer`/`Origin`; Komikcast/VoraToon
      additionally proves static `Sort`/`Sort Order`/`Status`/`Format`/`Type`
      filters plus bounded dynamic `Genre` fetch/retry/cache/concurrency and
      exact custom image headers through its JSON API; Yomu additionally proves
      bounded dynamic `Gênero` refresh, Next.js RSC parsing, URL-shaped search,
      strict-majority decoy filtering, and page-URL image headers. The dynamic
      caches are source-private and in-memory; their logical stream identities
      are not native zstd or persistent cross-launch storage. Arbitrary dynamic
      filters and the measured long tail remain open.
- [~] tachiyomix API bridge M3 (`HttpSource` → `KamiSource`) — the exact pinned
      BatCave 1.6.9, Kawii Manga 1.6.1, MangaMelon 1.6.1, Baozi Manhua
      1.6.29, TuttoAnimeManga 1.6.10, Mangas-Origines.fr 1.6.58,
      Komikcast/VoraToon 1.6.83, and Yomu Comics 1.6.59 profiles
      implement the measured app-facing contract through stable
      public wrappers; static
      `Sort`/`Select` filters, Baozi's bounded scalar preferences and interpreted
      custom image request, Mangas-Origines.fr's seven-filter/page-URL path, and
      Komikcast's and Yomu's bounded dynamic genre paths
      are proven; arbitrary dynamic/network-backed filters, production preference
      UI/persistence, source-executed image interceptors for page-URL profiles,
      and broader runtime coverage remain open
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
      the eight exact profiles and all 11 remaining measurement APKs produce
      deterministic results: 7 measurement candidates, 432 unique
      unregistered surfaces, zero omitted invocations, zero unsupported
      opcodes, and four stable-wrapper blockers (Komga, MangaPlus, NHentai.xxx,
      and XCOMIC); legacy lib 1.4 specimens remain explicit blockers
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
- [x] Expand the exact catalog with a sixth current extension —
      Mangas-Origines.fr 1.6.58 (metadata identity `Mangas-Origines.fr` / `fr` /
      `https://mangas-origines.fr`) is admitted by exact package
      `eu.kanade.tachiyomi.extension.fr.mangasoriginesfr`, version code `58`,
      SHA-256
      `b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b`,
      signer
      `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`,
      manifest, and source ID `4803238581797687746`. Deterministic real-APK
      regressions prove metadata, seven static filters, ordered POST
      popular/latest/search, details, chapters, pages, and page-URL image
      requests with `Referer`/`Origin`; no source-executed image-interceptor
      capability is claimed.
- [x] Expand the exact catalog with a seventh current extension — Komikcast /
      VoraToon 1.6.83 (metadata identity `VoraToon` / `id` /
      `https://v1.voratoon.com`) is admitted by exact package
      `eu.kanade.tachiyomi.extension.id.komikcast`, version code `83`, SHA-256
      `9420cd59844854ccad0a95353749b0ab41c9ddb797a6f43025fb1ddb4652c3ac`, v2
      signer
      `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`,
      manifest, source ID `972717448578983812`, and JSON API
      `https://api.voratoon.com`. Deterministic real-APK fixtures prove that
      the exact series URL `https://v1.voratoon.com/series/demo` routes through
      the bounded API detail path via `CollectionsKt.getOrNull`, plus metadata,
      popular/latest/text and filtered search, details, chapters,
      pages, exact custom image headers, static `Sort`/`Sort Order`/`Status`/
      `Format`/`Type` filters, dynamic `Genre` fetch/retry/cache/concurrency,
      and fail-closed tamper/schema/preferences. The dynamic cache is bounded,
      source-private, and in-memory; its zstd stream is a logical identity only,
      not native zstd or persistent cross-launch storage. Live-site,
      Cloudflare/challenge, source-scoped image-interceptor/transform, and
      arbitrary dynamic-filter compatibility remain unclaimed.
- [x] Expand the exact catalog with an eighth current extension — Yomu Comics /
      SSSCanlator 1.6.59 (metadata identity `Yomu Comics` / `pt-BR` /
      `https://yomu.com.br`) is admitted by exact package
      `eu.kanade.tachiyomi.extension.pt.sssscanlator`, version code `59`,
      SHA-256
      `2d7dfad2d4d293c58414b8905c6bcf454bcfb1a2bb6650a50d7480b0b9597883`,
      v2 signer
      `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`,
      manifest, and source ID `1497838059713668619`. Deterministic real-APK
      regressions prove metadata, popular/latest/text and edited-filter search,
      dynamic `Gênero` refresh, Next.js RSC details/chapters/pages, URL-shaped
      search, strict-majority decoy filtering, exact pagination, and inherited
      page-URL image headers. Live-site, Cloudflare/challenge, custom image
      transforms, source-scoped reader interceptors, and arbitrary dynamic-filter
      compatibility remain unclaimed.
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
      rewriting to final bytes. Mangas-Origines.fr page-URL image requests
      expose only validated URL/headers, including `Referer`/`Origin`, with no
      source-executed image-interceptor capability. Banner cropping remains
      unsupported until a bounded portable pixel/JPEG implementation exists;
      missing-image behavior is still unproven in reader image loads.
- [x] Carry each source's explicit insecure-HTTP policy into reader image
      fetching: pinned sources retain the factory policy, `ReaderView` passes
      it into `ReaderImagePipeline`, initial URL/headers are validated before
      injected or production transport, HTTPS is the default, and HTTP requires
      explicit source opt-in. Redirects use the same source-scoped policy.
- [x] On reader-image retry, regenerate and revalidate the source's
      `ImageRequest`, replace that page's request without resetting progress,
      and bypass cached bytes or superseded prefetches. Concurrent reloads must
      deduplicate. Requests are URL/header snapshots; explicit Retry refreshes
      them without merging old headers. There is no generic TTL or automatic
      authentication renewal. Local verification passes 262 MihonCompatKit and
      19 portable KamiCore tests. Exact checkpoint `fd15d76` passes all 262
      compatibility and 30 macOS core tests, including ImageIO decode recovery,
      plus simulator/device builds and unsigned IPA packaging; see HANDOFF.md
      for the three workflow runs. Physical-device interaction remains open.
- [ ] Harden regex execution with a bounded or demonstrably linear-time
      matcher (or an explicit match-step budget). Current `NSRegularExpression`
      use is bounded by pattern/input/output sizes but not by worst-case match
      time.
- [~] Production preference UI and persistence: FoolSlide has a closed, measured
      URL/adult schema and an authenticated SQLite configuration service in the
      current continuation. Other profiles retain their measured defaults.
- [x] Local compatibility diagnostics — typed runtime class/method/field/
      opcode failures are stage-deduplicated without arbitrary error strings;
      the first typed gap is retained below caught host-bridge fallbacks,
      external fields fail closed unless explicitly modeled, `compat-audit
      gaps` emits a deterministic path-free static/corpus priority report, and
      `compat-audit promote-gap` emits a deterministic focused XCTest seed.
      Extensions now exposes per-source inspection and user-selected Files
      export, with bounded canonical reports, explicit omissions and conservative
      typed-symbol validation. No automatic uploads or generic error logs —
      [#4](https://github.com/taizaki69/Kami/issues/4)
- [~] Verify bounded gzip/raw backup decoding against the Kotlin serializer;
      complete native export, previewed restore and source-identity handling.
      Current Mihon does not require the previously assumed zstd feature.

## P1 — Daily driver

- [x] Foreground downloads manager; active continuation above. Retry restarts
      partial chapters; background transfers and byte-range resume remain open.
- [x] Manual library update scanner, grouping and per-manga outcomes (PR #12).
      Scheduled updates and system notifications remain open.
- [x] Categories UI + management (PR #10); device interaction remains unverified.
- [x] Additive migration flow (multi-source search + reviewed unique-number
      chapter matching), read/bookmark transfer and optional categories.
      Original manga, history, page offsets and downloaded identities stay intact.
- [x] Manual ambiguous/unknown chapter pairing with one-to-one assignments,
      bounded local chapter search/pagination and renewed review after changes.
- [ ] Replace/remove-original mode, destination manga-search pagination and
      physical-device migration interaction.
- [x] Native backup export and reviewed restore UI with counts/conflicts.
- [x] Mihon import UI with measured English MangaDex mapping and coverage report.
- [ ] Broaden source mapping and supported Mihon fields with producer evidence.
- [x] Reader foundation: persistent LTR/RTL/webtoon modes, direction-aware tap
      zones, paged zoom/pan, settings, keep-awake, bounded header-aware image
      loading/prefetch, off-main downsampling, retry, and progress/history
- [x] Previous/next chapter flow (implemented before this continuation).
- [x] Reader tap-action, fit, crop and brightness controls; active continuation
      above. Physical gesture/brightness/multiwindow checks remain open.
- [x] Reader memory-warning response and cancellation-aware image ownership;
      see [verification](docs/VERIFICATION-2026-10-05-READER-MEMORY.md).
- [ ] Reader completion: cookie continuity for page-URL paths without a source
      executor, long-image region decoding and measured performance
- [ ] Cloudflare WKWebView bridge + cookie sync (M4)
- [x] Global search across enabled sources: progressive first-page previews,
      at most three provider queries at once, exact source/path identities and
      cancellation/replacement drainage. Open individual source search for
      pagination, retry and filters; see [global search](docs/GLOBAL_SEARCH.md).
- [x] Persistent source selection/language controls for Browse and global
      search, including all/none, remembered unavailable IDs, reviewed edits,
      stale-editor rejection and invalidation before queued queries/results.
      See [global search](docs/GLOBAL_SEARCH.md); Apple interaction remains
      separate from deterministic tests and exact-head compilation.
- [x] Migration review on top of global search and discovery preferences;
      bounded store-issued previews, atomic merge, stale-state rejection and
      shared exclusive commit. See [migration](docs/SOURCE_MIGRATION.md).

## P2 — Polish

- [ ] Local CBZ/ZIP source
- [~] Diagnostics screen: per-source runtime compatibility reports and explicit
      Files export are implemented. Broader app/storage/download diagnostics
      and Apple Files-provider interaction checks remain open; see
      [diagnostics](docs/COMPATIBILITY_DIAGNOSTICS.md).
- [ ] iPad dual-page reader
- [ ] Performance pass vs docs targets (launch, 5k-library, webtoon 500p)

## External validation remaining

- [ ] Install and smoke-test a signed build on a physical iPhone/iPad using
      user-owned Apple credentials (CI intentionally produces an unsigned IPA)
