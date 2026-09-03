# Kami Continuation Handoff

Last updated: 2026-09-03 (America/Lima)

This is the durable continuation point for moving Kami development to another
computer. The previous GLM 5.3 session stopped because its usage quota was
exhausted, not because the repository or build failed. Its intended Phase 2
work was recovered, completed, verified, and pushed.

The behavior-stratified measurement corpus is implemented at `35e4435`, and
its exact Apache-2.0 test fixtures are durably vendored at `a376064`. The
pre-Baozi continuation checkpoint is `e11931f`. The exact Baozi execution
profile is implemented at `9a1f647`. Bounded source-operation OkHttp
interceptor execution is implemented at `0ccb518`. Source-scoped reader-image
execution is implemented at `5535435`. Bounded observable reader-image redirect
follow-up is implemented at `c9d62f1`; all three exact-head GitHub Actions
workflows for that implementation commit pass. Operation-scoped first-gap
diagnostics, fail-closed external fields, inherited DEX header overrides, and
deterministic runtime-gap promotion are implemented at `b1cd246`; all three
exact-head workflows for that implementation commit pass too. The exact
TuttoAnimeManga 1.6.10 promotion is implemented at
`cf02c7735130c23956ad27226304808a20718566`; its exact-head workflow evidence is recorded below.
The exact Mangas-Origines.fr 1.6.58 promotion and hierarchy-aware app-entry
dispatch are implemented at
`0abc7f85637e36606acc75b516dc82b61e9682b4`; local evidence is recorded below
and all three exact-head GitHub Actions pass.

## Start here

- Repository: <https://github.com/taizaki69/Kami>
- Visibility: public (changed 2026-08-23 so standard GitHub-hosted Actions
  runners are free; publication preflight found no tracked secret patterns or
  sensitive credential filenames. The repository now includes 21 explicitly
  attributed, hash-locked third-party APK test fixtures, but the iOS target
  ships none of them.)
- Rights: Kami's original code is intentionally unlicensed and all rights are
  reserved by creator [taizaki69](https://github.com/taizaki69) while the
  proprietary/source-available/commercial/open-source decision remains open.
  Do not add a project license without the creator's explicit decision; see
  `LICENSES.md` and issue #5.
- Default branch: `main`
- Current verified pushed implementation checkpoint:
  `0abc7f85637e36606acc75b516dc82b61e9682b4` (the sixth exact current profile,
  Mangas-Origines.fr 1.6.58, plus hierarchy-aware app-entry dispatch, shared
  nested-async instruction budgeting, and only the measured Kotlin/Java/HTML
  surfaces required by its deterministic operations). Local and exact-head
  GitHub verification are complete below.
- Previous verified exact TuttoAnimeManga checkpoint:
  `cf02c7735130c23956ad27226304808a20718566`.
- Previous first-gap diagnostics checkpoint:
  `b1cd246d57d13884e83e77f03302c17c6e141d4d`.
- Previous observable-reader-redirect checkpoint:
  `c9d62f1a188b7fd9f1026fd5cc85155e269830c9` (GET-only reader-image
  single-exchange redirect visibility and bounded follow-up, retaining exact DEX
  Request/tags/configured client state and correct application-once/network-per-
  exchange ordering on top of the previous reader-image checkpoint).
- Previous source-scoped reader-image execution checkpoint:
  `553543597f13d5239e8ab3cf182bbadadbd486b4`.
- Previous bounded source-operation interceptor checkpoint:
  `0ccb518c63a657d6793d82ce888dd1f605d67b16`.
- Previous exact Baozi profile checkpoint:
  `9a1f64721d555ccac78e4506fbc0652e1da6e3bd`.
- Previous pre-Baozi continuation checkpoint:
  `e11931f86c630039098f6b9d3a45b0293bee5548` (the durable corpus milestone and
  its handoff documentation, also with successful exact-head workflows).
- Corpus-lock implementation baseline:
  `35e4435fd11c5160b0c78202b720ad70ec899216`
- Privacy-safe compatibility-diagnostics implementation baseline:
  `e56bd9ac2450eb7b558837e7fbc40633e81f3c98`
- Shared structural execution-plan baseline: `c1221935f25c7edd01b9efdc5ec794cf22454c8c`
- Native daily-reader foundation baseline: `6f6387e2707df51969c837a01f97388d07dc7331`
- User-facing filtered Browse baseline: `ad2b11869b1256ee7f1b7421c1ea66a78d367063`
- Third current filtered-profile baseline: `d4c036ddf109277fa6ec38d13beac8f6b52da09b`
- Authenticated source-surface discovery baseline: `8d12fc4685aaf91fec92aff23b9e35d5253302d6`
- Second current interpreted-profile baseline: `3802653cf89ed102b13de6e357e13b139ead3b6d`
- Stable public-wrapper routing baseline: `fcc89f89ad4f36e48166fc09a6611220577c1fb2`
- Trusted installation/source-factory baseline: `4d42def9dec5a9d884f2fb78982ba538b381114c`
- Signer-authenticated admission baseline: `a902d064af4c55edcb59a0048cbc87feb4292202`
- Pinned interpreted `KamiSource` baseline: `3708aa1e9deff88b24db767c4b19e18bca738b16`
- Page-list implementation baseline: `0555862278890ba78666a4b5c192421f0952a6be`
- Previous chapter-update baseline: `df11be5ee3f3dc67d66e76e2d4ba51c4a1ac51c8`
- Previous latest/details baseline: `4eca3b2866b8fe4088956d793dd31ec780bde2a3`
- Previous text-search baseline: `8d496330d1c5fd9e413164d12902d7b7cdb97eb7`
- Bounded HTML/popular parsing baseline: `f55a695f57aba7685fa51b563107f277e7503d37`
- Current macOS test-compiler portability checkpoint: `d6530fe4178155a2fc550654806937ecb99462a6`
- Previous macOS test-compiler portability baseline: `e5988c34692e795180f020dee67a4a90a993ee80`
- Current async transport/runtime implementation baseline: `6cb46b5ccbe600ca93847fdd270f8bfa02ecc690`
- Previous isolated HTTP transport baseline: `e58bf8e83bbc562e240f0f507f76cd8c42655e1c`
- Previous opcode-inventory baseline: `1293540`
- Previous parsed-DEX dispatch baseline: `f36a07a0a423c39287ae4efe37376c1eab459a35`
- Previous resolved-reference/typed-catch baseline: `b079d6912fc08b89fab4d654b92ada6d07ff73f0`
- Previous exact primitive/constructor-state baseline: `10bf770d61ebe1f6bb5dd9d13ade63853cdbffd8`
- Previous register-category baseline: `7ce3c812d5eca159a28d680591a45a72ff325956`
- Previous exception-verifier baseline: `66d41261e4cfa70bea2fd9a89a2f0dcdb670eff6`
- Previous structural-verifier baseline: `284b24dc2b7bec838afed5b6a2c9ea07df8b8f0b`
- Previous receiver-directed dispatch baseline: `057169640b43c516455f753ae3efd81e3db02e61`
- Previous request-model runtime baseline: `4d042c99a62536fbd894966286a1de7a93c5d0be`
- Previous exact-dispatch/class-initialization baseline: `05720d24d46d13b21e25dee2b95737b59fa65a9d`
- Code and documentation baseline before the original handoff: `4e50e6380c864e09205eb753c3ed7037780f9897`
- Original Phase 2 baseline: `6f9de0719f057646e228f14620806326840e5c75`
- Expected state after cloning: clean `main`, tracking `origin/main`

Always continue from the latest `origin/main`. The latest implementation head
is `0abc7f8`; the previous exact Tutto head is `cf02c77`; the first-gap diagnostics baseline is
`b1cd246`, the observable reader-image baseline is `c9d62f1`, the retained
source-execution baseline is `5535435`, the bounded source-operation interceptor
baseline is `0ccb518`, the exact Baozi profile baseline is `9a1f647`, and its
durable corpus implementation baseline is `a376064`. A documentation-only
continuation commit may be newer than the implementation head.

## Current resume point

Current verified state on 2026-09-03 (America/Lima):

- Commit `0abc7f8` is pushed to `main`. It promotes the exact
  Mangas-Origines.fr 1.6.58 APK as the sixth current app-facing profile after
  exact SHA-256, Keiyoushi signer, manifest/package/version, source-ID, and
  structural-plan checks. The exact identity is package
  `eu.kanade.tachiyomi.extension.fr.mangasoriginesfr`, SHA-256
  `b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b`, signer
  `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, and
  source ID `4803238581797687746`.
- Its unmodified DEX deterministically executes metadata, popular, latest,
  text and filtered search, details, chapters, pages, and its ordinary page-URL
  image request. The exact seven-entry filter graph is round-tripped; altered
  filters and unexpected preferences fail before transport. Its page image
  preserves inherited `Referer`/`Origin` headers and deliberately does not
  claim source-executed image interceptors.
- The runtime routes app-facing virtual entries through the receiver hierarchy
  and preserves one instruction budget across synchronous or asynchronous
  re-entry from a suspended host operation. Receiver identity, hierarchy
  assignability, inherited overrides, and the shared budget have focused
  regressions.
- The corpus remains 27 artifacts but is now split into eight execution, 13
  measurement-only, and six conformance fixtures. Nineteen artifacts are
  current lib 1.6: six execution and 13 measurement. The refreshed static audit
  is 13/13 analyzed, nine candidates, four blockers, 511 unique unregistered
  method surfaces, zero omitted invocations, and zero unsupported opcodes. Two
  optimized reports were byte-identical at 83,343 bytes with SHA-256
  `52b04c28af62c360f9b80c43591c255f471b3346966b84c58bb5174057bfa2b8`.
- Local Windows/Swift 6.3.3 verification passes 254/254 MihonCompatKit tests and
  17/17 portable KamiCore tests. Exact-head
  [Swift CI 33817169918](https://github.com/taizaki69/Kami/actions/runs/33817169918)
  passes 254/254 MihonCompatKit and 28/28 macOS KamiCore tests, builds the
  optimized CLI, and uploads it;
  [iOS Build 33817169894](https://github.com/taizaki69/Kami/actions/runs/33817169894)
  passes simulator and unsigned-device targets; and
  [IPA Package 33817169856](https://github.com/taizaki69/Kami/actions/runs/33817169856)
  builds and uploads the unsigned IPA.
- The next evidence-ranked execution target is Komikcast (42 statically
  unregistered surfaces). That number is only a prioritization signal, not
  runtime or compatibility proof.

Historical verified milestone ledger through 2026-08-30:

- Commit `35e4435` implements the corpus lock and tests. Commit `a376064`
  vendors the exact 21 Keiyoushi APKs with attribution so all 27 fixtures are
  present in a clean checkout. Commit `9a1f647` promotes exact Baozi Manhua
  1.6.29 to an admitted/executable profile. Commit `0ccb518` adds bounded
  source-operation interceptor execution and passes exact-head
  [Swift CI 33286986621](https://github.com/taizaki69/Kami/actions/runs/33286986621),
  [iOS Build 33286986601](https://github.com/taizaki69/Kami/actions/runs/33286986601),
  and [IPA Package 33286986710](https://github.com/taizaki69/Kami/actions/runs/33286986710).
  Commit `5535435` adds the source-scoped reader-image execution capability;
  it passes exact-head
  [Swift CI 33287959619](https://github.com/taizaki69/Kami/actions/runs/33287959619),
  [iOS Build 33287959646](https://github.com/taizaki69/Kami/actions/runs/33287959646),
  and [IPA Package 33287959622](https://github.com/taizaki69/Kami/actions/runs/33287959622).
  Commit `c9d62f1` adds reader-image single-exchange visibility, correct
  application/network redirect ordering, and sanitized bounded GET follow-up;
  it passes exact-head
  [Swift CI 33288777039](https://github.com/taizaki69/Kami/actions/runs/33288777039),
  [iOS Build 33288777021](https://github.com/taizaki69/Kami/actions/runs/33288777021),
  and [IPA Package 33288777024](https://github.com/taizaki69/Kami/actions/runs/33288777024).
  Commit `b1cd246` retains the first typed compatibility gap below caught
  host-bridge fallbacks, makes unknown external fields fail closed, executes inherited DEX
  `headersBuilder` overrides, and adds deterministic report-to-XCTest promotion;
  it passes exact-head
  [Swift CI 33289953550](https://github.com/taizaki69/Kami/actions/runs/33289953550),
  [iOS Build 33289953526](https://github.com/taizaki69/Kami/actions/runs/33289953526),
  and [IPA Package 33289953529](https://github.com/taizaki69/Kami/actions/runs/33289953529).
  Commit `cf02c77` promotes exact TuttoAnimeManga 1.6.10
  as the fifth app-facing profile, adds only the measured runtime surfaces
  needed by its real DEX, and passes exact-head
  [Swift CI 33342887303](https://github.com/taizaki69/Kami/actions/runs/33342887303),
  [iOS Build 33342887315](https://github.com/taizaki69/Kami/actions/runs/33342887315),
  and [IPA Package 33342887323](https://github.com/taizaki69/Kami/actions/runs/33342887323).
- The corpus lock is behavior-stratified at the 2026-08-23 snapshot:
  Keiyoushi catalog revision
  `4704d377ad00e7bc6f944cc7638a18e6e7fd4a23` and extensions-source revision
  `42771052f3e43b09a04d4b3f9073039690607476`. It contains 27 artifacts: seven
  execution fixtures, 14 measurement-only current lib 1.6 fixtures, and six
  AOSP conformance fixtures; 19 artifacts are current lib 1.6.
  Recorded upstream URLs remain provenance and best-effort fallback attempts
  only while reachable and only when the recovered bytes match the exact lock;
  `git restore Tests/corpus` is the durable recovery path. The current role
  split is seven execution fixtures (including Baozi and TuttoAnimeManga), 14 measurement-only
  current-lib-1.6 fixtures, and six AOSP conformance fixtures: 27 artifacts in
  total and 19 current-lib-1.6 artifacts.
- Static measurement parsed the remaining 14/14 measurement APKs: 10 are
  structural candidates, while Komga, MangaPlus, NHentai.xxx, and XCOMIC are
  the four stable-wrapper blockers. The aggregate report has 532 unique
  unregistered external surfaces and zero unsupported opcodes. These are static
  prioritization results only. Measurement membership grants no signer trust,
  admission, installation, DEX execution, or compatibility proof; release
  signature verification is parser conformance only.
- Three `CorpusLockTests` cover separated roles, manifest/fetch/hash round
  trips, manifest identity, release signature-parser conformance, and the
  deterministic static baseline. The fetch round trip passed, and the latest
  local Windows MihonCompatKit run passed 234/234 tests. The Baozi regression
  suite passed its construction, preference, filter, core-operation, and
  interpreted-image-request and observable redirect/follow-up checks against
  fake transport. Tutto's real-APK regressions cover every core source operation,
  exact GET requests and inherited headers, latest filtering/sorting/top-ten
  behavior, and fail-before-transport filter/preference rejection. Exact-head
  workflow evidence for the new implementation commit is recorded below; the
  previous `b1cd246` Swift CI run remains historical evidence for 223
  MihonCompatKit and 26 macOS KamiCore tests.
- Count continuity: the first-gap diagnostics milestone is 223/223
  MihonCompatKit and 15/15 portable KamiCore tests. The observable-redirect
  milestone was 220/220 MihonCompatKit and 15/15 KamiCore tests. The retained reader-image milestone was
  215/215 and 15/15. The bounded-interceptor milestone was 214/214
  and 14/14. The immediately preceding Baozi promotion was 207/207 and 14/14;
  pre-final-hardening reported 202/202
  and 13/13, and the earlier pre-Baozi source path reported 199/199. Those are
  historical only. The older exact corpus checkpoint remains 192/192
  MihonCompatKit and 23/23 KamiCore tests below.
- The pre-promotion 16-artifact optimized Windows `compat-audit gaps` runs
  exited 0 and produced byte-identical 98,876-byte UTF-8 reports with SHA-256
  `37503437e4b0aa67bf17fe13fa0b1d1b1d5ab05d5d2583964b2de0c0fcfd99e3`.
  Neither report contained a local-path, corpus-path, `.apk` filename, URL,
  auth, proxy-auth, `Set-Cookie`, `Bearer`, `token=`, or `password=` marker.
  Literal `Cookie` appears only in safe DEX API symbols, not as a claim of
  zero generic `Cookie` text; the current 14-artifact baseline is the one to
  use for prioritization.
- Baozi Manhua `eu.kanade.tachiyomi.extension.zh.baozimanhua@1.6.29(29)` is
  the fourth exact current-lib profile. Its admission gates require
  SHA-256 `7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`,
  the Keiyoushi signer fingerprint
  `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, the
  authenticated manifest, and declared source ID `5724751873601868259`.
  Deterministic fake-transport regressions cover construction, the bounded
  scalar preference surface, the exact static filter shape, popular/latest/
  search/details/chapters/pages, and the DEX `imageRequest` URL rewrite. They
  also apply a valid non-default Baozi tag state and observe a distinct filtered
  request; mutated filter schemas fail before transport. The reader now
  resolves each page's `ImageRequest` asynchronously. With an explicitly
  supported configuration, that value carries an opaque UUID capability while
  the source actor retains the exact DEX Request/tags and configured client in
  a 4,096-entry-bounded table. KamiCore validates the URL/header projection,
  includes the UUID in in-flight/cache identity, invokes the source chain, and
  then enforces its existing 2xx/non-empty/image-size checks. The real Baozi
  direct-302 fixture proves its redirect-domain tag rewrites `Location` while
  preserving body and unrelated headers. A second exact-APK fixture uses the
  production-shaped single-exchange seam, observes the raw 302, follows the
  rewritten source-host URL, and returns final image bytes. Application
  interceptors wrap the reader call once and network interceptors run on every
  exchange; all hops share the redirect, cancellation, VM, and 64-step budgets,
  retain tags, and strip explicit cross-origin secrets before follow-up.
  Production preference UI/persistence
  is not wired. Because the APK defaults its optional Android Bitmap banner
  transform to mode 1, the downloaded-source factory explicitly supplies
  `BAOZI_BANNER=0`; explicit preferences override it. Bitmap/pixel/JPEG crop
  behavior remains unsupported. The response-sequence seam is intentionally
  limited to supported GET-only reader images; general source-operation,
  non-GET, and broader OkHttp retry parity remain unproven.
- TuttoAnimeManga
  `eu.kanade.tachiyomi.extension.it.tuttoanimemanga@1.6.10(10)` is the fifth
  exact current-lib profile. Its admission gates require SHA-256
  `e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3`, the
  Keiyoushi signer fingerprint
  `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, its
  authenticated manifest, and declared source ID `2102507871480604746`.
  Deterministic real-APK regressions execute metadata, popular, latest, text
  search, details, combined chapter update, chapter list, pages, and ordinary
  page-URL image requests. They prove exact GET URLs, path-segment encoding,
  inherited `Referer`/`Origin`, ten-minute request caching, sparse-details URL
  preservation, nullable list/integer decoding, scanlator joining, latest
  null filtering/raw timestamp ordering/top-ten limiting, and rejection of
  unsupported filters/preferences before transport. This proves only the exact
  locked APK against deterministic responses; it does not prove live-site
  availability or arbitrary PizzaReader-family compatibility.
- The downloaded-source factory preflights each exact profile source-ID set
  before DEX construction and postvalidates every constructed ID against that
  set and the persisted admission. `SourceRegistry` removal is package-owner
  scoped. Raw exact-byte profile constructors remain a deliberate built-in/test
  seam and reverify exact hash/signer; downloaded execution requires persisted
  admission and the sole factory. Source-model outputs are bounded at the host
  seam (2,048 manga/page entries, 20,000 chapters per update, and 8 KiB `Page`
  URL/image URL fields). Chapter retry uses structured `.task(id: reloadID)` and
  dismissal cleanup invalidates its load generation; retry-time image-request
  regeneration/expiry and bounded or linear-time regex hardening remain deferred
  TODOs. Reader image fetching now inherits the source's admitted transport
  policy, defaults to HTTPS-only, validates URL/headers before injected or
  production transport, and permits HTTP only through explicit source opt-in;
  redirect policy remains source-scoped as well. Ordinary page-URL profiles
  strip source-derived credentials from cross-origin initial image requests
  while retaining safe CDN headers such as `Referer`/`Origin`. Supported interpreted reader
  requests also reuse the source transport and cookie jar instead of creating
  a detached image session.

Historical pushed checkpoints (preserved below; prior stop state was
2026-08-23, America/Lima):

- Commit `e56bd9a` is pushed to `main`. Every exact interpreted source now owns
  a bounded thread-safe `InterpretedCompatibilityRecorder`. Failed app-facing
  operations record only propagated typed unresolved class, exact method
  signature, field, or unsupported-opcode VM errors, deduplicated and counted
  by operation stage. Cancellation, budgets, verifier strings, HTTP/parser
  failures, and arbitrary error descriptions are ignored so dynamic URLs,
  queries, headers, cookies, bodies, credentials, and user data never enter the
  report. A real BatCave `.popular` failure regression proves the report is
  actionable without serializing the source URL.
- `InterpretedCompatibilityAudit` non-executingly scans decoded instruction
  boundaries across all APK DEX entries, reconciles locally defined classes,
  compares exact external method prototype/staticness with `HostBridge`, and
  aggregates unregistered invocations, unsupported opcodes, and sanitized plan
  blockers. `compat-audit gaps` supports one file or deterministic directory
  order, replaces filenames with artifact ordinals, continues after generic
  malformed-artifact errors, and returns failure only after reporting the full
  batch. Unregistered virtual/interface invocations remain an explicitly
  heuristic priority signal, not runtime failure, trust, admission, or
  execution proof.
- Local verification for `e56bd9a` passes all 189 MihonCompatKit and 12
  portable KamiCore tests plus the optimized Windows CLI build. Two full
  release `gaps` corpus reports were byte-identical (`SHA-256
  c0eebf80a9846bc45a02ffacd2e26691f0deb1f8efecc12c445bd96f1679b8c2`) and
  contained none of the checked local-path, APK-filename, URL, authorization,
  cookie, bearer, token, or password markers. Its exact-head workflows pass:
  [Swift CI 32683073872](https://github.com/taizaki69/Kami/actions/runs/32683073872),
  [iOS Build 32683073885](https://github.com/taizaki69/Kami/actions/runs/32683073885),
  and [IPA Package 32683073873](https://github.com/taizaki69/Kami/actions/runs/32683073873).
- Commit `c122193` is pushed to `main`. A reusable
  `InterpretedExtensionPlanInspector` now performs bounded, non-executing
  manifest/ZIP/DEX discovery shared by the exact runtime and
  `compat-audit plan`. It produces either a deterministic lib 1.6 execution
  structure or stable blockers for invalid identity, factories, unsupported
  libraries, missing/ambiguous/multiple DEX, native `.so` entries, entry-class
  placement, and stable public-wrapper discovery.
- A structural plan is deliberately not signer trust, persisted admission,
  catalog membership, source-ID authority, or execution proof. The existing
  three-entry exact catalog remains fail-closed. BatCave, Kawii Manga, and
  MangaMelon produce repeatable plans; Akuma and MangaDex remain explicit lib
  1.4 blockers instead of being guessed. The exact profiles now consume the
  shared plan only after their hash/signature/manifest/catalog gates.
- The CLI accepts one APK or a directory in deterministic filename order. It
  continues reporting later artifacts after malformed entries and returns a
  failing final status if any could not be inspected. The full local corpus
  audit therefore reports all three current candidates, both legacy blockers,
  the unrelated AOSP non-extension/native-library shapes, and the intentionally
  malformed fixture.
- Local verification for `c122193` passes all 185 MihonCompatKit and 12
  portable KamiCore tests plus the optimized Windows `compat-audit` build. Its
  exact-head workflows pass:
  [Swift CI 32680137538](https://github.com/taizaki69/Kami/actions/runs/32680137538)
  runs 185 MihonCompatKit and 23 macOS KamiCore tests plus the optimized CLI,
  [iOS Build 32680137584](https://github.com/taizaki69/Kami/actions/runs/32680137584)
  compiles Simulator and unsigned device targets with zero warning lines, and
  [IPA Package 32680137545](https://github.com/taizaki69/Kami/actions/runs/32680137545)
  uploads the unsigned IPA. The added upside-down portrait orientation removes
  the earlier iPad multitasking warning without forcing full-screen mode.
- Commit `6f6387e` is pushed to `main`. The native reader now has persistent
  left-to-right, right-to-left, and continuous webtoon modes; direction-aware
  tap zones; paged double-tap/pinch zoom and pan; configurable background,
  prefetch, webtoon gap, and keep-awake; retry/chrome/progress; restored
  last-page position; history persistence; and mark-read on the final page.
- Reader images now use the exact source `ImageRequest` URL and headers instead
  of `AsyncImage`. A source-scoped actor provides streamed response limits,
  redirect/header policy, an isolated cookie jar, in-flight deduplication, a
  bounded compressed LRU, capped prefetch, cancellation-safe reset, and
  off-main ImageIO validation/downsampling. Paged decoded images are limited to
  the current page and neighbors; lazy webtoon pages release decoded images as
  they leave the viewport. Runtime-to-reader cookie continuity is still open.
- Local verification for `6f6387e` passes all 182 MihonCompatKit and 12
  portable KamiCore tests. Its exact-head workflows pass:
  [Swift CI 32678304601](https://github.com/taizaki69/Kami/actions/runs/32678304601)
  runs 182 MihonCompatKit and 23 macOS KamiCore tests plus the optimized CLI,
  [iOS Build 32678304615](https://github.com/taizaki69/Kami/actions/runs/32678304615)
  compiles Simulator and unsigned device targets, and
  [IPA Package 32678304614](https://github.com/taizaki69/Kami/actions/runs/32678304614)
  uploads the unsigned IPA.
- Commit `ad2b118` is pushed to `main`. Browse now renders all eight
  app-facing Mihon filter cases: headers, separators, selects, text,
  checkboxes, tri-state values, nested groups, and sort selections. The sheet
  edits a copy, Cancel is non-mutating, Reset restores the source defaults,
  Clear exits filter-only mode, and Apply deliberately supports blank-query
  filtered search.
- Every text search now carries the source's full filter shape with default or
  user-edited state, so MangaMelon no longer fails its schema gate when
  searched from the app.
  `SourceBrowseRequest` makes popular/latest/text/filter-only routing a tested
  KamiCore seam. Browse also uses reset generations to ignore stale async
  responses, advances pagination only after success, disables duplicate load-
  more requests, supports pull-to-refresh, and hides Latest for sources that do
  not advertise it.
- Local verification for `ad2b118` passes all 182 MihonCompatKit and 9 portable
  KamiCore tests. Its exact-head workflows all pass:
  [Swift CI 32676159196](https://github.com/taizaki69/Kami/actions/runs/32676159196)
  runs 182 MihonCompatKit and 20 macOS KamiCore tests plus the optimized CLI,
  [iOS Build 32676159129](https://github.com/taizaki69/Kami/actions/runs/32676159129)
  compiles Simulator and unsigned device targets, and
  [IPA Package 32676159183](https://github.com/taizaki69/Kami/actions/runs/32676159183)
  uploads the unsigned IPA.
- Commit `d4c036d` is pushed to `main`. MangaMelon 1.6.1 is the third exact
  current lib 1.6 profile and the first to prove app-facing filter state. Its
  authenticated APK supplies a static `Sort`/`Select` schema; the runtime
  rejects changed names/options/shape before transport, mutates only validated
  state on the original DEX filter instances, and executes popular, latest,
  filtered search, combined details/chapters, and pages with exact offline
  request/response assertions.
- MangaMelon's measured host additions remain deny-by-default: UTF-8-only
  string bytes, bounded Okio `ByteString`/Base64, JSON `encodeDefaults` and
  `Long`, structured coroutine lambdas represented without arbitrary host task
  creation, bounded stable comparator sorting, and a string-valued JSON memo
  subset. The full regression proves chapter memo propagation, Kotlin Instant
  dates, sorted chapters/pages, and exact default-inclusive form JSON.
- Commit `8d12fc4` removed per-profile copies of stable lib 1.6 public API
  signatures. It derives metadata and the local public wrapper location from
  each exact authenticated APK while retaining exact SHA-256, cryptographic
  signer, package/version/lib, entry-class, declared source-ID, and factory
  admission checks. Its exact-head Swift CI, iOS Build, and IPA workflows all
  passed.
- Local verification for `d4c036d` passed 182 MihonCompatKit tests, 8 portable
  KamiCore tests, the five-extension corpus lock/fetch round trip, and optimized
  Windows release builds for both packages. Exact-head GitHub runs are
  [Swift CI 32674896127](https://github.com/taizaki69/Kami/actions/runs/32674896127),
  [iOS Build 32674896114](https://github.com/taizaki69/Kami/actions/runs/32674896114),
  and [IPA Package 32674896131](https://github.com/taizaki69/Kami/actions/runs/32674896131),
  all passed.
- Commit `3802653` is pushed to `main`. The exact Kawii Manga 1.6.1 APK is the
  second current source profile to cross every measured app-facing core
  operation: metadata, popular, latest, text search, combined details/chapters,
  and pages. Its deterministic regression asserts every exact JSON GET and the
  source's `x-app-key` header on all five requests. The profile is locked by
  package/version, SHA-256, signer fingerprint, manifest/entry class, and source
  ID just like BatCave.
- The same commit closes the measured runtime gaps Kawii reached: bounded
  `HttpUrl.Builder` query construction, exact custom `headersBuilder` execution,
  nullable and boolean generated serialization, nullable case-aware string
  equality, ordered `distinct` with a comparison budget, character-delimiter
  substring defaults, and Kotlin `Instant` epoch conversion. The DEX verifier
  accepts R8's unreachable payload-alignment NOP only behind a terminal
  instruction with no branch, switch, or handler entry.
- Earlier commit `fcc89f8` routes profiles through stable public
  `KeiSource`/`HttpSource` wrappers found on either a local superclass or the
  generated entry after R8 vertical merging, so app-facing profiles no longer
  map R8-private worker names. It passed
  [Swift CI 32668840038](https://github.com/taizaki69/Kami/actions/runs/32668840038),
  [iOS Build 32668840056](https://github.com/taizaki69/Kami/actions/runs/32668840056),
  and [IPA Package 32668840065](https://github.com/taizaki69/Kami/actions/runs/32668840065).
- Commit `4d42def` is pushed to `main`. Kami now has a durable, capability-gated
  extension product flow. `ExtensionInstallationService` downloads repository
  entries into content-addressed app storage, validates repository metadata,
  and either uses the repository's pinned signing key or stages the already
  verified bytes for explicit legacy-store certificate-fingerprint
  confirmation. Updates inherit sticky trust, require signer continuity, and
  preserve the existing enabled state. Canceled or failed installs do not leave
  reusable trust state.
- `ExtensionAdmissionService.restore` issues a fresh capability only for an
  enabled persisted install whose bounded regular file still has the exact
  stored SHA-256, cryptographic signature scheme/current signers/history,
  explicit-user fingerprint when applicable, and package/version manifest.
  `ExtensionSourceFactory` is the only consumer: it re-reads the exact bytes it
  will execute into one bounded immutable buffer, repeats hash/signature/
  manifest verification, uses the exact profile catalog, and rejects runtime
  source IDs not declared by the repository. Unsupported profiles fail closed.
- The app persists/removes extension repositories, pins a non-empty repository
  signing key against later removal or substitution, provides install/update
  and enable/disable UI, re-authenticates enabled installs on startup, disables
  failed restorations, and shows active downloaded sources beside native ones
  in Browse. Downloaded updates replace the old runtime; disabling removes it;
  the protected native source ID cannot be shadowed. Browse routes text and
  blank-query filtered searches with the source's complete filter shape.
- The exact measured profile catalog contains BatCave 1.6.9, Kawii Manga
  1.6.1, and MangaMelon 1.6.1. An
  arbitrary authenticated extension can be stored securely, but it cannot be
  enabled or heuristically executed until a measured profile exists.
- Exact implementation-head `3802653` passes
  [Swift CI 32670599504](https://github.com/taizaki69/Kami/actions/runs/32670599504),
  [iOS Build 32670599479](https://github.com/taizaki69/Kami/actions/runs/32670599479),
  and [IPA Package 32670599498](https://github.com/taizaki69/Kami/actions/runs/32670599498).
  This verifies 179 MihonCompatKit tests, the optimized CLI, all 18 macOS
  KamiCore tests, Simulator/device targets, and the unsigned IPA artifact.
  Locally, 179 MihonCompatKit and 7 portable KamiCore tests pass on
  Windows/Swift 6.3.3.
- Earlier commit `a902d06` established the signer gate. `APKSignatureVerifier` performs bounded
  APK v2, v3/v3.1, and conservative v1/JAR verification with RSA PKCS#1/PSS and
  ECDSA, X.509/SPKI matching, AOSP chunked content digests, v3 proof-of-rotation,
  and signature-stripping protection. Fingerprints exactly match Mihon's
  lowercase SHA-256-over-certificate-DER format. Unsigned, malformed, tampered,
  wrong-signer, and stripped inputs are rejected without returning an identity.
- `ExtensionAdmissionService` verifies the signature before manifest or DEX
  work, matches package/version metadata, requires repository-declared or
  explicit-user signer trust, and atomically persists APK hash/path, signer
  history, trust origin, and declared source IDs. Updates cannot downgrade,
  replace bytes under one version code, or break the verified signer lineage.
  `SourceRegistry` has separate pinned and downloaded paths; the latter requires
  the internal-init persisted admission capability and a declared source ID.
- Six focused verifier regressions cover real Keiyoushi v2 APKs plus vendored
  AOSP v1, v3, rotated, unsigned, invalid-signature, tampered-content, and
  stripped-scheme fixtures. KamiCore separately checks unrelated repository
  signers and update identities. The tiny AOSP fixtures and full Apache-2.0
  license are tracked. The exact real-extension fixtures are now vendored under
  their upstream Apache-2.0 license and checked by hash; they are not app assets.
- Issue #3 is closed with the final evidence in
  [comment 5388393509](https://github.com/taizaki69/Kami/issues/3#issuecomment-5388393509).
  The exact-head typed-error hardening is recorded in
  [comment 5388440829](https://github.com/taizaki69/Kami/issues/3#issuecomment-5388440829).
- Commit `3708aa1` is pushed to `main`. `PinnedInterpretedSource` admits only
  the exact BatCave 1.6.9 bytes after SHA-256, manifest package/lib/entry-class,
  and DEX class validation, then exposes its real metadata, popular, latest,
  paginated text search, combined details/chapters, pages, and default image
  requests through `KamiSource`. One actor owns the mutable interpreter,
  receiver, and source-scoped transport; a bounded cancellation-aware queue
  prevents overlapping VM entry across async suspension. Production transport
  disables plain HTTP by default.
- `LibraryService.refresh` now uses an optional combined `SMangaUpdate` protocol
  seam, so BatCave refreshes details and chapters with one real source request
  while existing native sources retain the sequential default. `SourceRegistry`
  accepts and deduplicates the interpreted source without source-kind branches.
- Three deterministic adapter tests exercise every currently claimed
  `KamiSource` operation, exact requests/results, default page image conversion,
  a one-byte APK tamper rejection before parsing, and serialized concurrent
  calls. A KamiCore regression proves registry integration. Swift Crypto 3.12.5
  supplies cross-platform SHA-256 and is exactly locked and attributed; its
  Apache-2.0 license applies to that dependency, not to Kami's original code.
- Commit `f55a695` is pushed to `main`. It pins SwiftSoup 2.9.6 and places a
  resource-bounded HTML5/CSS layer behind the exact Jsoup methods reached by the
  pinned BatCave APK. Limits cover input bytes, DOM nodes/depth/attributes,
  selector length/results/cumulative work, and extracted strings.
- The host bridge now supplies the reached `Document`, `Element`, `Elements`,
  `SManga`, `MangasPage`, and `HttpSource.setUrlWithoutDomain` behavior. The
  real BatCave popular worker sends its exact POST, crosses the deterministic
  async transport, parses production selectors, and returns an exact two-entry
  app-facing `MangasPage` with relative URLs and pagination.
- Commit `8d49633` is pushed to `main`. BatCave's real nonblank text-search worker
  now trims and Java-form-encodes a page-2 query, builds the exact GET with its
  600-second cache policy, and parses the response into the expected no-next-page
  manga result. The R8-renamed worker is invoked directly because its external
  KeiSource superclass bridge is not implemented yet.
- Commit `4eca3b2` is pushed to `main`. BatCave's public latest-updates operation
  builds the exact cached page-3 GET and returns a paginated `MangasPage`. Its
  real generated manga-details worker builds the cached detail GET and returns
  URL, title, thumbnail, publisher/year description, author, artist, genres,
  and status. The shared bridge now supplies bounded Kotlin default collection
  joining plus modern Jsoup direct-child `:has(> ...)` and element-relative
  `> ...` selector semantics missing from SwiftSoup 2.9.6.
- Commit `df11be5` is pushed to `main`. BatCave's real combined manga-update
  worker reuses the cached detail GET, selects
  `script:containsData(window.__DATA__)`, performs bounded extraction, drives
  the APK's generated `Chapters`/`Chapter` serializers through a generic
  bounded JSON decoder, and returns exact `SChapter` values in `SMangaUpdate`.
  The fixture proves multiple chapters, xhash URLs, fractional numbers,
  source-local dates, invalid-date fallback, malformed JSON rejection, and
  required-field rejection. Exact measured Kotlin string/Result/number,
  Java-time, Jsoup, and tachiyomix model shims support that path.
- Commit `0555862` is pushed to `main`. BatCave's real public page-list worker
  splits the chapter URL, runs the APK's generated request serializer, emits
  the exact JSON POST, decodes `ChapterApiResponse.data.images` from a bounded
  Okio source through the generated response serializers, normalizes relative
  and absolute image URLs, constructs Tachiyomi `Page` values, and converts
  them to exact public `PageCompat` results. Malformed JSON, invalid UTF-8, and
  a wrong images type all become typed `SerializationException`s. The reusable
  surface adds bounded Kotlin split/regex/affix helpers, ordered generated JSON
  encoding, String/list decoding, close-finally cleanup, and `Page` models.
- Commit `d6530fe` is pushed to `main`. It rewrites one synthetic async DEX test
  fixture as incremental array appends so Swift 6 on macOS can type-check it in
  reasonable time; runtime behavior and fixture bytes are unchanged.
- All 182 MihonCompatKit tests pass locally on Windows/Swift 6.3.3, including 6
  signer regressions, 21 source/execution test paths against the five pinned
  execution fixtures, 7 focused
  HTML/parser-limit tests, bounded Java URL-encoding and Kotlin
  string/collection/time regressions, and 4 async interpreter/transport tests
  plus 3 BatCave adapter regressions and the complete Kawii and MangaMelon
  profiles. KamiCore's 9 portable Windows tests pass; exact-head macOS CI runs
  all 20, including the Browse request-routing regression and
  SQLite admission, repository persistence, install/restore/factory, enabled
  state, and update-policy suite. The optimized
  MihonCompatKit/`compat-audit` build also passes.
- The earlier `6cb46b5` async runtime still captures nested DEX frames, awaits
  without blocking, resumes inside-out with shared budgets and typed handlers,
  propagates cancellation, and exposes bounded OkHttp response/body values.
- A real-APK regression still proves a 503 response reaches Mihon's exact
  `HttpException(code: 503)`.
- Publishing the repository removed the private-repository Actions billing
  dispatch block. A public rerun of `0555862` passed iOS Build and IPA Package;
  Swift CI reached the compiler and exposed the test-only expression fixed in
  `d6530fe`. Exact-head `d6530fe` then passed
  [Swift CI 32660907795](https://github.com/taizaki69/Kami/actions/runs/32660907795),
  [iOS Build 32660907782](https://github.com/taizaki69/Kami/actions/runs/32660907782),
  and [IPA Package 32660907773](https://github.com/taizaki69/Kami/actions/runs/32660907773).
- Exact-head `3708aa1` passes
  [Swift CI 32662751000](https://github.com/taizaki69/Kami/actions/runs/32662751000),
  [iOS Build 32662750970](https://github.com/taizaki69/Kami/actions/runs/32662750970),
  and [IPA Package 32662751023](https://github.com/taizaki69/Kami/actions/runs/32662751023).
  This verifies the 165-test adapter suite, optimized CLI, 2 KamiCore tests,
  Simulator/device targets, and unsigned IPA.
- GitHub CLI is installed and authenticated as `taizaki69`; repository and
  workflow access were working. No authentication setup should be needed on
  this computer.
- The six pinned extension APKs are present locally and still match the lock
  file: Akuma 1.4.10, MangaDex 1.4.212, BatCave 1.6.9, Kawii Manga 1.6.1,
  MangaMelon 1.6.1, and Baozi Manhua 1.6.29.
- Issue #1 has the completed dispatch-milestone evidence in
  [progress comment 5384204450](https://github.com/taizaki69/Kami/issues/1#issuecomment-5384204450)
  and remains open intentionally.
- Issue #2 has the chapter checkpoint in
  [progress comment 5387853914](https://github.com/taizaki69/Kami/issues/2#issuecomment-5387853914)
  and the page checkpoint in
  [progress comment 5387957141](https://github.com/taizaki69/Kami/issues/2#issuecomment-5387957141).
  Its final [completion comment 5388156079](https://github.com/taizaki69/Kami/issues/2#issuecomment-5388156079)
  records exact local and CI evidence. The issue is closed as completed at
  `3708aa1`; general compatibility remains separate work.

### Completed diagnostics/discovery milestones and next frontier

The first interpreted `KamiSource`, signer-authenticated admission gate, durable
installation/selection flow, and exact-byte source factory are complete under
deterministic fixtures. Preserve this established trust order:

```text
selected extension store + declared signing identity
  -> bounded APK v2/v3/v3.1 signer verification (v1 fallback where required)
  -> normalized certificate identity
  -> explicit persisted initial trust decision
  -> content-addressed installed package/version/signer binding
  -> update signer continuity and enabled-state preservation
  -> startup exact-file re-authentication
  -> fresh executable-source capability
  -> exact measured profile construction from the same bytes
  -> declared source-ID validation and registry insertion
```

Issue #3's valid, tampered, wrong-signer, rotated-signer, unsigned, and stripped
fixtures plus the install/restore/factory regressions enforce this order. Stable
public wrapper discovery and six current lib 1.6 profiles are now complete;
MangaMelon proves the first exact static filtered-search path, while Baozi adds
bounded scalar preferences, its exact static filter graph, core source
operations, and a DEX-defined image-request rewrite. TuttoAnimeManga adds an
independent PizzaReader path with real JSON serialization, nullable integer/list
decoding, latest sorting/limiting, inherited headers, and ordinary page-URL
image requests. Mangas-Origines.fr adds a second independent HTML-heavy path,
an exact seven-entry filter graph, French locale/date handling, and ordinary
page-image headers; changed filters/preferences fail before transport. Typed runtime gap reporting
and the non-executing static corpus ranking seam are also complete. At
`b1cd246`, the observer sits at public VM entry boundaries so the first typed
gap survives a nested host-bridge catch; unknown external instance/static
fields fail with exact diagnostics unless explicitly modeled, and
`compat-audit promote-gap` emits a deterministic focused XCTest seed. The same
runtime correction executes inherited DEX `headersBuilder` overrides without
exception probing, so every BatCave source request now carries its exact
`Referer` and `Origin` headers. Corpus
locking remains rooted at `35e4435`/`a376064`; after Mangas-Origines.fr
promotion the behavior-stratified snapshot has 8 execution, 13
measurement-only current lib 1.6, and 6 AOSP conformance artifacts, with 13/13
measurement APKs parsed.

The bounded source-operation OkHttp application/network interceptor seam and
the source-scoped reader-image execution seam are complete. They preserve DEX
Request identity/tags, use immutable registration-order snapshots, enforce at
most 32 interceptors, 64 interceptor/terminal steps, depth 32, one `proceed`
per chain object, cancellation at every edge, transport response limits, and a
single VM instruction budget. Reader execution retains DEX values only inside
the source actor, bounds live handles at 4,096, keeps hidden execution identity
out of KamiCore except for an opaque UUID, and reuses the source cookie jar.

The bounded intermediate-response/follow-up seam is now complete for supported
GET-only reader images. The active compatibility frontier is evidence-driven
promotion of the next locked structural candidate using the completed first-gap
and regression-seed tooling. Mangas-Origines.fr has graduated into exact
execution; Komikcast is the next evidence-ranked candidate with 42 statically
unregistered surfaces, but that count remains a ranking signal rather than
execution evidence. Issue #4 remains partial only for app-facing local
report export/share. Keep Baozi banner transformation unsupported until a bounded
portable pixel/JPEG implementation exists; a metadata-only Bitmap shim is not
compatibility. Dynamic/network-backed filters and production preference
UI/persistence also remain open.
Generate more of the exact catalog only
from authenticated evidence, and do not let discovery create a parallel
admission bypass. Keep `HostBridge` deny-by-default and never execute extension
native libraries.

Start with:

```bash
git switch main
git pull --ff-only
git status --short --branch
swift test --package-path Packages/MihonCompatKit
swift build --package-path Packages/MihonCompatKit -c release --product compat-audit
swift run --package-path Packages/MihonCompatKit compat-audit gaps Tests/corpus
swift run --package-path Packages/MihonCompatKit compat-audit gaps Tests/corpus/measurement
```

The direct `Tests/corpus` command intentionally includes malformed
`aosp-unsigned.apk`, so that command reports all later artifacts and then exits
70. That is the expected batch-error contract, not an early audit failure. The
nested `Tests/corpus/measurement` command should complete successfully after
the vendored corpus is verified.

On this Windows checkout, use the checked-in helper for the test command if
needed. Keep real extension execution offline and limited to the eight
`Tests/corpus/*.apk` execution fixtures. The nested
`Tests/corpus/measurement/*.apk` fixtures are for static analysis only and
must never be executed. Only `ExtensionAdmissionService` may turn downloaded
bytes into a persisted eligibility capability.

## Clone and restore the workspace

The repository is public, so cloning does not require authentication. GitHub
CLI authentication is still useful for pushes and workflow administration:

```bash
gh auth login
gh repo clone taizaki69/Kami
cd Kami
git switch main
git pull --ff-only
git status --short --branch
```

The final status command should show `main...origin/main` with no tracked
changes.

### macOS: full iOS development

Requirements: Xcode 15 or newer and xcodegen.

```bash
brew install xcodegen
bash scripts/bootstrap.sh
bash scripts/test.sh
bash scripts/build.sh
bash scripts/package_ipa.sh
```

The app target is iOS 17.0. The Swift packages retain an iOS 16.0 minimum.
`Kami.ipa` is unsigned; use only credentials owned by the developer when
signing or installing it.

### Windows or Linux: portable packages

The compatibility layer is portable. It was verified with Swift 6.3.3 on
Windows; Swift 5.9 or newer is the intended minimum.

```bash
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
swift build --package-path Packages/MihonCompatKit -c release --product compat-audit
swift run --package-path Packages/MihonCompatKit compat-audit gaps Tests/corpus
```

On Windows, prefer the checked-in helper when the Swift driver behaves
inconsistently from the active shell. It discovers the latest Visual Studio C++
x64 environment with `vswhere` and locates the installed user-local Swift
toolchain/runtime/SDK instead of relying on machine-specific hard-coded paths:

```bat
scripts\windows_dev_test.bat Packages\MihonCompatKit test
scripts\windows_dev_test.bat Packages\MihonCompatKit release
```

After changing a public MihonCompatKit value layout at `e56bd9a`, an incremental
KamiCore test binary retained stale dependency ABI and crashed in
`swiftCore.dll`; this was not reproducible after
`scripts\windows_dev_test.bat Packages\KamiCore clean`, and the clean rebuild
passed 12/12. If a future Windows-only access violation appears immediately
after a public dependency change, clean that dependent package before treating
it as a source regression.

The iOS app itself still requires macOS and Xcode.

### Verify the vendored extension corpus

The 27 exact APK fixtures are stored in Git for deterministic clean-clone and
CI verification. Run:

```bash
bash scripts/fetch_corpus.sh
```

The script verifies seven SHA-256-pinned Keiyoushi execution fixtures, 14
SHA-256-pinned current lib 1.6 measurement fixtures under the nested
`Tests/corpus/measurement/` directory, and six AOSP conformance fixtures against
`Tests/corpus/manifest.json`. A recorded upstream URL is only a best-effort
fallback for a missing or hash-mismatched file; `git restore Tests/corpus` is
the durable recovery path after upstream release rotation. On Windows, run the
script from Git Bash or WSL.

Do not copy these generated or ignored paths between computers:

- `Packages/KamiCore/.build/`
- `Packages/MihonCompatKit/.build/`
- generated `.xcodeproj`, `DerivedData/`, `dist/`, or IPA files

The ignored `Tests/corpus/index.pb` is not required by the pinned APK execution
suite. The nested measurement APKs are vendored static-analysis fixtures only;
they must not be admitted or executed.

Never commit `.env` files, Apple certificates, provisioning profiles, P12
files, passwords, cookies, or signing credentials.

## Known-good verification checkpoint

Current local Mangas-Origines.fr-promotion evidence, based on the durable corpus established
by `35e4435`/`a376064`: the behavior-stratified lock and fetch round trip cover
27 artifacts (8 execution, 13 measurement-only current lib 1.6, and 6 AOSP
conformance; 19 current lib 1.6 total). The 3 `CorpusLockTests` pass
manifest/fetch/hash, manifest-identity, signature-parser-conformance, and
deterministic-baseline assertions. The latest local Windows MihonCompatKit run
is 254/254 and portable KamiCore is 17/17. The current optimized measurement
`compat-audit gaps` runs were
byte-identical 83,343-byte UTF-8 reports with SHA-256
`52b04c28af62c360f9b80c43591c255f471b3346966b84c58bb5174057bfa2b8` and no
local-path, corpus-path, `.apk` filename, URL, auth, proxy-auth, `Set-Cookie`,
`Bearer`, `token=`, or `password=` marker; literal `Cookie` appears only in safe
DEX API symbols. Exact-head Swift CI `33817169918` verified all 27 committed
fixtures without a corpus fallback download, passed 254 MihonCompatKit and 28
KamiCore tests, built the optimized CLI, and uploaded it.

Verification detail:

| Check | Result |
|---|---|
| MihonCompatKit | 254/254 Swift tests passed locally on Windows/Swift 6.3.3, including corpus-lock, eight-APK signer, six-profile structural-plan, privacy-safe diagnostics, transport/interceptor, and full Baozi/Tutto/Mangas-Origines.fr real-APK regressions; the prior 234-test Tutto, 223-test first-gap, and 192-test exact-corpus checkpoints remain historical evidence below |
| KamiCore | 17/17 portable tests passed locally on Windows/Swift 6.3.3, including exact Baozi, Tutto, and Mangas-Origines.fr factory admission plus source-scoped image execution; exact head `0abc7f8` passed 28/28 macOS tests |
| Optimized package builds | Windows release builds passed for both MihonCompatKit/`compat-audit.exe` and KamiCore |
| Real APK constructors | Akuma, MangaDex, BatCave, Kawii Manga, MangaMelon, Baozi Manhua, TuttoAnimeManga, and Mangas-Origines.fr passed |
| Structural execution plans | BatCave, Kawii Manga, MangaMelon, Baozi Manhua, TuttoAnimeManga, and Mangas-Origines.fr produce deterministic single-DEX lib 1.6 plans; Akuma/MangaDex report lib 1.4 blockers; malformed input throws; full CLI batches continue after per-file errors and fail at the end |
| Compatibility diagnostics | The first typed runtime gap is retained at the VM boundary below caught fallbacks and stage-deduplicated while arbitrary errors are ignored; unknown external fields fail closed unless explicitly modeled; a failed BatCave operation yields the exact missing method without its URL; `promote-gap` emits a deterministic focused XCTest seed; static reports are deterministic/order-independent, sanitized, non-executing, and carry no admission authority; two release CLI corpus runs matched byte-for-byte with zero checked secret/path markers |
| Structural verifier | 10 focused regressions cover instruction geometry, branch/fallthrough boundaries, R8's unreachable alignment NOP, and aligned, bounded, correctly typed payloads and switch targets |
| Exception/control verifier | 13 focused regressions cover strict try/catch decoding, resolved `Throwable` validation, typed handler state/execution, and AOSP branch/result/exception-entry rules |
| Register dataflow verifier | 21 focused regressions cover dead-code bounds, parameter seeding, common-supertype joins, polymorphic constants, exact primitive/wide/reference assignments, array covariance, result/invoke types, wide-pair clobbering, exception edges, and constructor/uninitialized-object state |
| Runtime reference semantics | 4 focused regressions cover resolved and unresolved typed-catch dispatch plus hierarchy-aware `check-cast` and `instance-of` |
| Binary opcode semantics | 1 focused regression covers AOSP operation/type-major ordering across int, long, float, double, and `/2addr` forms |
| Method resolution and receiver dispatch | 16 focused regressions cover virtual/class override selection, direct hierarchy-aware app entry and receiver identity, lexical normal/range class-super dispatch, inherited/maximally-specific interface defaults, abstract masking, default conflicts, DEX 037 interface-super gating, strict interface receivers, typed linkage failures, and conservative unresolved boundaries |
| Request/model/collection host regressions | 31 focused tests cover request construction, bounded `HttpUrl.Builder`, duration/cache/time/locale conversion, URL scheme rejection, CRLF-header rejection, body/work bounds, strict nullable JSON integers, Java URL encoding, nullable equality, bounded Kotlin split/regex/affix/string/list/set/map helpers, Mangas-Origines.fr HTML surfaces, and fail-closed typed `ArrayList.toArray` stores |
| HTTP transport regressions | 11 focused tests cover source isolation, bounded deterministic encoding, source-image credential origin binding, redirect secret stripping/downgrade rejection, streamed response limits, cancellation, cookie scope, one-exchange 3xx visibility, and safe GET follow-up construction |
| Async interpreter/response regressions | 7 focused tests cover nested frame resumption, typed DEX handler re-entry, synchronous and asynchronous virtual-entry re-entry under one instruction budget, cancellation, injected transport, and bounded response state |
| OkHttp interceptor execution | 9 focused tests cover application/network descent and reverse unwind, exact Request/two-tag identity, response builder/header/body/redirect semantics, one-shot `proceed`, the 32-interceptor limit, shared outer VM budget, final-chain `await` versus `awaitSuccess`, cancellation, application-once/network-per-exchange reader redirects, retained follow-up tags, and a 64-step budget shared across hops; Baozi core operations traverse the real finite rate limiter |
| HTML/selector hardening | 9 focused tests cover BatCave and Mangas-Origines.fr CSS/URL semantics, body-fragment parsing, sibling/attribute/`eachText`, modern direct-child and `:containsData` selectors, input, base-URL, node, depth, attribute, selector length/result/work, and extracted-string limits |
| BatCave execution | Exact metadata getters pass; popular, paginated text search, and latest updates return exact `MangasPage`; core details return exact `SManga`; combined updates return exact chapters; page list returns exact image URLs; every request carries the inherited DEX `headersBuilder`'s exact `Referer`/`Origin`; malformed chapter/page payloads are typed failures; a 503 maps to `HttpException(code: 503)` |
| Kawii Manga execution | Exact metadata, popular/latest/search, combined details/chapters, and pages pass from the locked APK; all five exact GETs carry the custom `x-app-key` header |
| MangaMelon execution | Exact metadata, static `Sort`/`Select` filters, popular/latest/filtered search, combined details/chapters, memo, and ordered pages pass from the locked APK; exact default-inclusive Base64 form JSON is asserted and a mutated schema fails before transport |
| TuttoAnimeManga execution | Exact metadata, popular/latest/text search, details, combined chapters/update, chapter list, pages, inherited `Referer`/`Origin`, cache policy, nullable JSON values, scanlator/chapter-number conversion, latest sort/top-ten behavior, and no-filter/no-preference rejection pass from the locked APK against deterministic responses; this is not live-site proof |
| Mangas-Origines.fr execution | Exact metadata, seven-entry static filters, popular/latest/text and filtered search, details, chapters, pages, inherited `Referer`/`Origin`, French date parsing, and ordinary page-URL image request pass from the locked APK against deterministic responses; altered filters and unexpected preferences fail before transport; this is not live-site proof |
| Filtered Browse UI | All eight app-facing filter cases render transactionally; text search preserves the full source shape, blank-query Apply routes to filtered search, Clear exits filter-only mode, and reset generations reject stale result appends |
| Native reader | LTR/RTL paged and continuous webtoon targets compile; persistent settings, tap/chrome/zoom/retry/progress/history/read-state behavior and bounded decoded-page retention are wired; portable tests prove settings/prefetch bounds and the source-header-aware image pipeline |
| Pinned source adapters | BatCave, Kawii, MangaMelon, Baozi, Tutto, and Mangas-Origines.fr regressions cover every claimed `KamiSource` contract, including source-scoped image behavior and Baozi rewrite-to-final-bytes redirect follow-up; KamiCore covers registry insertion/deduplication, reader-policy enforcement, and exact Baozi/Tutto/Mangas-Origines.fr factory admission |
| APK signer verification | Focused regressions cover the eight real Keiyoushi v2 APKs (Akuma, MangaDex, BatCave, Kawii Manga, MangaMelon, Baozi Manhua, TuttoAnimeManga, and Mangas-Origines.fr), AOSP v1/v3 and verified rotation, content/signature tampering, unsigned input, fingerprint normalization, and scheme stripping |
| Persisted extension admission | 3 focused macOS test methods cover repository/user trust, unrelated-signer rejection, declared source-ID capability registration, verified signer rotation, and downgrade/same-version replacement rejection |
| Install/restore/source factory | Historical macOS install tests plus current portable factory tests cover repository-key install, explicit legacy confirmation, cancellation, startup restoration, exact-file replacement rejection, declared source-ID enforcement, real BatCave/MangaMelon/Baozi/Tutto/Mangas-Origines.fr construction, and refusal to guess an unmeasured profile |
| Swift CI | Exact Mangas-Origines.fr implementation head `0abc7f8` [run 33817169918](https://github.com/taizaki69/Kami/actions/runs/33817169918) verified all 27 fixtures without fallback download, passed 254/254 MihonCompatKit and 28/28 macOS KamiCore tests, built the optimized CLI, and uploaded `compat-audit-macos`; `cf02c77` run 33342887303 is the historical 234/27 Tutto baseline |
| iOS Simulator and unsigned device builds | Exact Mangas-Origines.fr implementation head `0abc7f8` [run 33817169894](https://github.com/taizaki69/Kami/actions/runs/33817169894) passed both targets |
| Unsigned IPA packaging | Exact Mangas-Origines.fr implementation head `0abc7f8` [run 33817169856](https://github.com/taizaki69/Kami/actions/runs/33817169856) passed and uploaded `Kami-unsigned-ipa`; this is unsigned build/package evidence, not a signed release |
| Repository integrity | implementation commit `0abc7f8` was cleanly pushed; staged and working diffs passed `git diff --check`; prior full `git fsck --full` found no corruption |

The exact-head public-repository runs validate every implementation checkpoint
through `0abc7f8`, including the durable corpus, first-gap runtime/static
compatibility diagnostics, shared non-executing plan discovery, all six
app-facing interpreted source profiles,
signer-authenticated admission gate, durable install/restore flow, exact-byte
factory, source selection UI, filtered Browse, source registration, and the
native reader foundation, source-scoped reader-image execution, observable GET
redirect handling, and deterministic compatibility-regression promotion. They produced both `compat-audit-macos` and
`Kami-unsigned-ipa` artifacts.

## What the preceding first-gap continuation completed (historical checkpoint)

Commit `b1cd246` completed the preceding first-gap diagnostics frontier without
changing signer trust, admission, or the then-four-entry executable catalog:

- Each runtime source operation installs one scoped VM observer. Public
  synchronous, asynchronous, nested asynchronous, and defined-override entries
  report the first accepted typed class/method/field/opcode gap before a nested
  host-bridge fallback can catch and replace it. Cancellation, budget,
  verification, HTTP, parser, and arbitrary errors do not consume that slot.
- External instance/static fields now fail with exact `unresolvedField`
  diagnostics unless the DEX owns the declaring class or the host explicitly
  models that exact field. Reached Kotlin and OkHttp singleton/ref fields are
  explicit rather than silently defaulted.
- `HttpSource.getHeaders` finds a real DEX-defined virtual override without
  exception probing. This fixes BatCave's inherited `headersBuilder`; exact
  `Referer: https://batcave.biz/` and `Origin: https://batcave.biz` now reach
  every deterministic source request.
- `compat-audit promote-gap <runtime-report.txt>` strictly parses the bounded,
  canonical redacted v1 report and emits a deterministic paste-ready XCTest
  assertion seed. It never echoes the path or raw report on failure.
- Seven focused diagnostics regressions plus empty-report assertions on all
  four exact profiles bring local MihonCompatKit verification to 223/223;
  KamiCore remains 15/15 on portable Windows. Exact-head Swift CI passes
  223/223 and 26/26, builds/uploads the optimized CLI, and both iOS targets and
  unsigned IPA packaging pass.

The immediately preceding milestone adds bounded observable redirects for supported source-scoped
GET reader images without weakening the exact Baozi profile's hash, signer,
manifest, admission, or declared-source-ID checks:

- `URLSessionCompatHTTPTransport` now optionally returns one response without
  following a redirect, while retaining its source cookie jar, streamed limits,
  cancellation, and policy validation.
- Reader application interceptors wrap the whole call once; network
  interceptors run for every raw response. Rewritten `Location` values drive
  sanitized follow-ups that retain exact tags, strip explicit cross-origin
  credentials, enforce five redirects, and share the existing 64-step/depth/VM
  budgets.
- Generic regressions prove per-hop ordering, retained tag identity,
  cross-origin secret stripping, cookie handling, downgrade/redirect limits,
  and one shared chain budget. The real Baozi APK rewrites a raw 302 to its
  source host and the next exchange returns final image bytes.

The underlying source-operation interceptor foundation remains:

- `await`/`awaitSuccess` snapshot application then network interceptors in
  registration order, preserve the exact DEX Request/tags through each
  `Chain.request`/one-shot `proceed`, and unwind responses in reverse order.
  They preserve the outer VM instruction budget and check task/call/VM
  cancellation at every edge.
- The host caps clients at 32 interceptors, calls at 64 interceptor/terminal
  steps and depth 32, and replacement bodies/headers at the transport policy.
  Response rebuilding preserves request identity and supports the exact
  redirect/header/code/body operations reached by Baozi.
- The original seven focused regressions prove order, two-tag identity,
  response rebuilding, one-shot proceed, client caps, the shared VM budget,
  final-chain
  `await`/`awaitSuccess` behavior, and cancellation. Baozi's ten real-profile
  regressions pass, and its core operations traverse its real finite
  rate limiter.
- The refreshed non-executing measurement baseline is 15/15 parsed, 11
  structural candidates, 540 unique unregistered external method surfaces, and
  zero unsupported opcodes.
- Local Windows verification for that observable-redirect milestone passed
  220/220 MihonCompatKit tests and 15/15 KamiCore tests. Its exact
  head `c9d62f1` passes
  [Swift CI 33288777039](https://github.com/taizaki69/Kami/actions/runs/33288777039),
  [iOS Build 33288777021](https://github.com/taizaki69/Kami/actions/runs/33288777021),
  and [IPA Package 33288777024](https://github.com/taizaki69/Kami/actions/runs/33288777024).
- Reader-facing `ImageRequest` can now carry an opaque UUID capability while
  the source actor retains the exact DEX Request/tags/configured client and
  executes the completed bounded chain. Baozi's direct-302 fixture proves its
  redirect-domain rewrite. Commit `c9d62f1` adds an optional no-follow transport
  exchange, application-once/network-per-exchange reader ordering, retained-tag
  follow-ups, cross-origin secret stripping, source-policy redirect bounds, and
  exact Baozi rewrite-to-final-bytes proof. Banner cropping and general
  source-operation/non-GET response-sequence parity remain explicitly
  unsupported/unproven.

The following corpus and diagnostics entries are preserved as the immediately
preceding milestones and their historical evidence.

Commit `35e4435` locks the behavior-stratified 27-artifact corpus at the
2026-08-23 Keiyoushi catalog/source revisions, adds 3 `CorpusLockTests`, and
records 16/16 static measurement parses with 12 structural candidates, four
stable-wrapper blockers, 626 unique unregistered surfaces, and zero unsupported
opcodes. Commit `a376064` durably vendors the exact bytes and attribution. The
combined milestone passes the fetch round trip, local Windows 192/192
MihonCompatKit run, and exact-head Swift/iOS/IPA workflows. The 21 Keiyoushi
APKs total 1,560,928 bytes and are tracked only as attributed test fixtures
because upstream release assets rotate. This remains measurement and
parser-conformance evidence only: it does not grant trust, admission,
installation, DEX execution, or compatibility proof.

Commit `e56bd9a` establishes the first privacy-safe compatibility measurement
seam without expanding execution or admission:

- Exact interpreted sources expose a bounded deterministic runtime report after
  an operation fails. Only typed VM API/opcode identities and the operation
  stage are admitted; arbitrary error text and dynamic request/response values
  cannot be serialized.
- `InterpretedCompatibilityAudit` and `compat-audit gaps` rank unregistered
  external method prototypes and unsupported opcodes across a corpus without
  executing DEX. The public report embeds only sanitized plan status, and the
  CLI emits artifact ordinals and generic errors rather than paths/filenames.
- Four focused regressions bring MihonCompatKit to 189 tests. Local full tests,
  clean dependent-package tests, optimized compilation, byte-for-byte corpus
  determinism/privacy checks, both Xcode destinations, unsigned IPA packaging,
  and all three exact-head workflows pass. At that historical checkpoint,
  issue #4 still lacked app export, below-catch first-gap and broader
  field/bridge instrumentation, and automatic fixed-gap regression promotion;
  `b1cd246` subsequently completes the runtime/tooling portions.

Earlier commit `c122193` establishes the first shared structural-plan seam:

- `InterpretedExtensionPlanInspector` turns bounded manifest/ZIP/DEX facts into
  either a deterministic `InterpretedExtensionExecutionPlan` or capability-
  oriented blockers without DEX execution or trust side effects. The exact
  profiles and diagnostic CLI now use the same entry/wrapper discovery.
- The inspector requires the current single-source, single-DEX lib 1.6 shape,
  rejects source factories and every embedded `.so`, and never treats a plan as
  admission or operation-level proof. The exact three-profile runtime catalog
  and persisted signer/source-ID gates are unchanged.
- `compat-audit plan` supports bounded single-file and deterministic directory
  reports. Per-file parse failures no longer hide later corpus results; the
  final exit remains nonzero when any artifact is malformed.
- Three focused regressions bring MihonCompatKit to 185 tests. All local tests,
  the optimized Windows CLI, both Xcode destinations, the unsigned IPA, and all
  three exact-head workflows pass. The same checkpoint also supplies the full
  iPad orientation set required for multitasking without a build warning.

Earlier commit `6f6387e` establishes the first bounded daily-driver reader foundation:

- Persistent LTR, RTL, and webtoon experiences share progress, history,
  keep-awake restoration, settings, chrome, retries, and a tested prefetch
  plan. Paged images support zoom/pan and direction-aware tap zones; webtoon
  progress follows the page with the largest visible intersection.
- `ReaderImagePipeline` forwards exact source headers through the hardened
  transport, caps streamed compressed images and cache/prefetch state,
  deduplicates identical work, and prevents canceled lifecycle generations
  from clearing or caching newer requests. ImageIO rejects extreme metadata
  and downsamples away from the main actor.
- Three portable regressions bring KamiCore to 12 Windows and 23 macOS tests.
  Both Xcode destinations and unsigned IPA packaging pass at the exact code
  checkpoint. Remaining reader work is kept explicit in `docs/READER.md`.

Earlier commit `ad2b118` exposes the measured filter contract as a native
Browse feature:

- `SourceFilterSheet` transactionally renders header, separator, select, text,
  checkbox, tri-state, nested group, and sort cases. Apply supports blank-query
  search, Reset restores source defaults, Clear exits filter-only mode, and
  Cancel never mutates the active request state.
- Browse always sends the complete source filter schema on text search, hides
  unsupported Latest feeds, supports pull-to-refresh, advances pages only on
  success, disables duplicate load-more requests, and discards results from
  superseded reset generations.
- `SourceBrowseRequest` provides a pure, portable routing seam. Its regression
  distinguishes popular, latest, trimmed text search, and blank filter-only
  search. Exact-head CI passes 182 MihonCompatKit and 20 KamiCore tests plus
  both iOS build destinations and IPA packaging.

Commits `8d12fc4` and `d4c036d` complete authenticated source-surface discovery
and the third exact current source profile:

- Stable lib 1.6 public method signatures are centralized once; the exact
  authenticated APK supplies entry metadata and the local wrapper-chain
  location. Exact artifact hash, signer, manifest identity, source ID, and
  admission remain mandatory.
- MangaMelon 1.6.1 is locked into the corpus/profile catalog. It executes every
  core source operation and the first validated app-facing static `Sort`/
  `Select` filter round trip, with malformed schema rejection before network.
- The measured host surface adds bounded UTF-8/Okio/Base64 request encoding,
  JSON defaults/longs/memo, structured coroutine lambdas, and stable sorting;
  it adds no native-library, filesystem, Android-context, or general heuristic
  execution capability.

Earlier commits `fcc89f8` and `3802653` completed stable public-wrapper routing
and the second exact current source profile:

- Profile operations now call public `KeiSource` wrappers found on either the
  entry class or its local superclass chain. This tolerates the two measured R8
  layouts without mapping private worker names.
- Kawii Manga 1.6.1 is locked into the exact profile catalog and executes every
  core source operation under deterministic transport with its exact custom
  header and URL construction.
- New host/runtime support is limited to methods reached by the real APK and is
  independently bounded; focused tests cover URL expansion and quadratic
  collection work limits.

Earlier commit `4d42def` completed trusted extension installation, restoration,
source construction, and selection:

- `ExtensionInstallationService` owns content-addressed durable APK storage.
  Repository-keyed first installs complete without a prompt; legacy stores
  stage cryptographically verified bytes until the user confirms a displayed
  certificate fingerprint. Pending confirmations are hash-bound, cancellation
  removes the stage, updates retain sticky trust and enabled state, and old APK
  files are removed only after successful replacement admission.
- `ExtensionAdmissionService.restore` reads only enabled persisted installs and
  checks the bounded regular file, exact hash, complete signature identity,
  signer history, user trust, and manifest before issuing a new capability.
- `ExtensionSourceFactory` is the only admission consumer. It authenticates the
  same immutable buffer it passes to `InterpretedExtensionProfileCatalog`,
  requires repository-declared source IDs, and rejects unsupported profiles.
  The catalog now contains exact BatCave 1.6.9, Kawii Manga 1.6.1, and
  MangaMelon 1.6.1 profiles.
- Repositories and their normalized signing keys persist. Key removal or
  substitution is rejected; unavailable repositories remain listed and can be
  removed. The Extensions UI installs/updates and enables/disables; AppModel
  restores safely on startup; SourceRegistry replaces/removes downloaded
  runtimes without allowing the native source to be shadowed; Browse displays
  source origin and routes source search through the current full filter shape.
- Exact-head workflows prove 182 MihonCompatKit tests, 20 macOS KamiCore tests,
  optimized CLI output, both iOS build destinations, and the unsigned IPA.

Earlier commits `86125f9` through `a902d06` completed signer-authenticated
extension admission:

- `APKSignatureVerifier` authenticates the APK Signing Block and signed content
  for v2/v3/v3.1, verifies v3 proof-of-rotation, and implements a conservative
  v1 manifest/SF/CMS fallback. It supports the modern RSA PKCS#1/PSS and ECDSA
  algorithms exercised by the locked corpus and returns Mihon-format
  certificate fingerprints only after verification.
- `ExtensionAdmissionService` verifies before manifest/DEX work, binds exact
  package and version metadata, and accepts only repository-declared or
  explicit-user signer trust. SQLite schema v2 persists the APK digest/path,
  signature scheme, current signers/history, trust origin, and source IDs.
- Update admission requires monotonically increasing version codes, identical
  bytes for the same version, and either a verified single-signer lineage or an
  exact multi-signer set. The original trust origin remains sticky.
- The general public registry insertion method is gone. Compiled pinned sources
  use `addPinned`; downloaded sources require an internal-init persisted
  `ExtensionAdmission` and one of its declared source IDs.
- Six tiny AOSP apksig fixtures and the exact real-extension corpus are tracked
  with Apache-2.0 attribution and pinned hashes. They eliminate live Gitiles and
  rotating-release dependencies without becoming app assets or admission proof.
- Their exact-head workflows proved 171 MihonCompatKit tests, 8 macOS KamiCore tests,
  optimized CLI output, both iOS build destinations, and the unsigned IPA.
  Issue #3 is closed. Those capabilities now feed the install/restore/factory
  path completed at `4d42def`.

Commit `f55a695` crosses the measured Jsoup boundary without pretending the
source is end-to-end complete:

- SwiftSoup 2.9.6 is exactly pinned as the Swift 5.9-compatible HTML5/CSS engine
  and recorded under its MIT license.
- Kami owns independent untrusted-input limits around parsing, DOM shape,
  selector work/results, and extracted strings.
- Exact Jsoup document/element/elements registrations plus the reached
  `SManga`/`MangasPage` model surface let BatCave's real parser return an exact
  app-facing popular page from deterministic HTML.
- Five focused hardening tests and the pinned real-APK result bring the suite to
  148 tests.

Commit `8d49633` then adds the measured Kotlin trim and Java UTF-8 form-encoding
surface. The real BatCave text-search worker proves its exact page-2 GET, cache
policy, parsed manga fields, and false pagination result; the focused encoder
test and pinned search path bring the suite to 150 tests.

Commit `4eca3b2` adds the public latest-updates and core manga-details paths:

- The pinned APK builds the exact cached page-3 latest GET and returns the
  expected paginated `MangasPage` from deterministic production-shaped HTML.
- Its real generated details worker builds the exact cached detail GET and
  returns URL, title, thumbnail, publisher/year description, author, artist,
  genres, and ongoing status.
- A bounded Kotlin `joinToString$default` shim supplies genre joining and rejects
  oversized output. The SwiftSoup adapter supplies the modern Jsoup
  direct-child relative-selector behavior reached by details while charging
  every compatibility pass against the cumulative selector budget.
- Two real-APK paths and three focused regressions bring the suite to 155 tests.

Commit `df11be5` adds the combined manga-update/chapter path:

- The pinned APK reuses its exact cached detail GET, extracts
  `window.__DATA__`, executes its real generated DTO deserializers, and returns
  two exact chapters inside `SMangaUpdate`.
- The bounded generic JSON decoder supports the measured generated descriptor,
  nested-list, primitive, default, and required-field surface while limiting
  input and decoded structure. Malformed JSON and a missing required field both
  become typed `SerializationException`s.
- Exact Kotlin delimiter substring helpers, `Result`/number behavior, the
  reached `java.time` path, Jsoup `:containsData`, and `SChapter`/`SMangaUpdate`
  models support the reusable compatibility slice. KamiCore preserves both the
  tachiyomix 1.6 float chapter number and its newer string number.
- Two new real-APK paths, one HTML regression, one Kotlin-helper regression,
  and one KamiCore model regression bring MihonCompatKit to 159 tests and
  KamiCore to 1 currently runnable Windows test.

Commit `0555862` adds the page-list path:

- The pinned APK parses `/reader/42/7?token=test`, executes its generated
  `ChapterRequestBody` serializer, and sends the exact ordered JSON body to the
  exact reader endpoint through the injected transport.
- The bounded Okio JSON path executes the real `ChapterApiResponse`/`Images`
  generated deserializers, including `List<String>`, then the APK trims and
  normalizes relative/absolute URLs and constructs two Tachiyomi `Page` values.
  Public conversion returns exact `PageCompat` indexes and image URLs.
- Strict UTF-8, JSON input/output and structure limits, Kotlin split/regex/
  affix bounds, one-shot buffered-source consumption, and close-finally cleanup
  preserve the deny-by-default runtime boundary. Malformed JSON, invalid UTF-8,
  and a wrong images type are typed `SerializationException`s.
- Two real-APK page tests and one focused helper regression bring
  MihonCompatKit to 162 tests. KamiCore's dependency test and the optimized
  package/CLI build also pass.

Commit `d6530fe` then replaces a second compound synthetic DEX fixture expression
with incremental appends so Swift 6 can type-check it on macOS. The exact-head
Swift CI, iOS Build, and IPA Package workflows all pass; this changes test
construction only, not runtime semantics.

Commit `3708aa1` completes the first pinned app-facing source adapter:

- A compiled BatCave 1.6.9 profile contains the exact APK digest, manifest
  identity, entry descriptor, metadata expectations, and already measured DEX
  method names/prototypes. Digest and identity checks happen before VM creation;
  a one-byte mutation is rejected before parsing.
- One source actor owns `DexInterpreter`, the instantiated receiver, and its
  transport. Its bounded FIFO and cancellation handoff prevent concurrent
  mutation while the actor is reentrant across async HTTP suspension.
- Popular, latest, paginated text search, combined details/chapters, pages, and
  validated default HTTP(S) image requests flow through `KamiSource`; filtered
  and blank search remain explicit unsupported boundaries rather than silently
  returning misleading results.
- `KamiSource.getMangaUpdate` has a backwards-compatible sequential default.
  The adapter overrides it with BatCave's one-request combined worker, and
  `LibraryService.refresh` consumes that seam. `SourceRegistry` needs no
  interpreted-source special case.
- Swift Crypto 3.12.5 is exactly pinned for cross-platform SHA-256, with its
  transitive Swift ASN.1 lock and third-party attribution recorded. Kami remains
  intentionally unlicensed/all rights reserved pending issue #5.
- MihonCompatKit reaches 165 passing Windows tests and KamiCore reaches 2; the
  optimized package/CLI build also passes.

Earlier commit `6cb46b5` crossed the asynchronous extension HTTP boundary:

- `DexInterpreter.callAsync` snapshots exact nested frames at async host
  invocations, awaits without blocking, resumes inside-out, preserves the
  shared instruction budget, and supports repeated suspension. A thrown DEX
  value re-enters the typed handler covering the original invoke instruction;
  Task cancellation becomes `VMError.cancelled`.
- `HostBridge` has exact sync and async method registries. Synchronous `call`
  reports `asyncExecutionRequired` instead of leaking an internal suspension.
  No async network method exists unless a source-scoped transport is injected.
- Mihon's `await` and `awaitSuccess` execute the prepared request. Transport
  failures become redacted `IOException` values; `awaitSuccess` accepts only
  2xx and otherwise throws a modeled Mihon `HttpException` with its code.
- Bounded `Response`, `ResponseBody`, `Headers`, and `BufferedSource` host values
  expose the reached status/header/body/charset/one-shot read behavior using
  only the already bounded transport response.
- Four focused async regressions and two pinned BatCave paths brought that
  historical suite to 143 tests and moved the real-APK frontier from
  `awaitSuccess` to `JsoupExtensionsKt.asJsoup$default`.

Earlier commit `e5988c3` similarly split a different compound DEX test-fixture
expression for the macOS compiler; it made no runtime semantic change.

Commit `e58bf8e` immediately before it supplies the isolated production
URLSession transport: per-source actor ownership, redirect/timeout/request and
response limits, streaming response-body enforcement, cancellation, and an
in-memory source-isolated cookie jar.

## What the preceding dispatch continuation completed

Commit `f36a07a` completes parsed-DEX class-super and interface-default method
resolution for the current DEX runtime milestone:

- A shared method resolver now selects normal virtual methods from the runtime
  class chain, lets class declarations override interface defaults, and applies
  maximally specific interface-default rules across parsed interface graphs.
  Abstract subinterfaces mask parent defaults, unrelated concrete defaults
  conflict, and incomplete external relationships or native/no-code methods
  remain unresolved instead of being guessed.
- Class `invoke-super` and `invoke-super/range` dispatch relative to the lexical
  caller's direct superclass, so a grandparent method reference correctly
  reaches an override in the immediate parent. DEX 037+ interface
  `invoke-super` searches only the referenced interface graph and ignores class
  overrides and sibling interfaces.
- The verifier now checks class/interface invoke kinds, static/direct/virtual
  method-list placement, interface invoke version gates, locally resolvable
  method references, and lexical supertype relationships. Unknown external
  targets continue to soft-verify.
- Resolved abstract, missing, conflicting-default, and known non-implementing
  receiver failures surface as typed `AbstractMethodError`,
  `NoSuchMethodError`, or `IncompatibleClassChangeError` values.
- `DexFile` exposes its numeric format version. The controlled DEX builder now
  emits multiple sorted class definitions, selectable 035/037-040 magic,
  per-class interfaces/fields/methods, explicit access flags, and abstract or
  native no-code declarations.
- Thirteen new regressions bring MihonCompatKit to 126 passing tests, including
  91 interpreter tests and all eight pinned real-extension paths. The debug and
  release compatibility builds plus the KamiCore dependency build/test pass on
  Windows/Swift 6.3.3; Swift CI, both iOS targets, and IPA packaging pass on the
  exact SHA.

Remaining issue #1 work is broader external class-graph and super/default
resolution, remaining opcode coverage, and differential AOSP fixtures.

## What the preceding resolved-reference continuation completed

Commit `b079d69` completes the resolved-reference and typed-catch portion of the
DEX verifier/runtime milestone:

- A shared conservative hierarchy resolves parsed DEX superclasses and
  interfaces plus the bounded Java/Kotlin classes modeled by `HostBridge`.
  Assignability is tri-state so absent external library graphs soft-verify
  instead of causing speculative rejection.
- Reference-array covariance, exact primitive-array compatibility, and
  common-superclass joins now preserve useful verifier types. Explicit external
  superclasses named by parsed DEX definitions remain part of those joins even
  when their own class bodies are outside the APK.
- Returns, invoke receivers/arguments, constructor receivers, field receivers
  and values, array writes, filled arrays, and throws reject resolved unrelated
  reference types. Ordinary interface assignment retains ART's non-strict
  verifier behavior; runtime checks use strict hierarchy traversal.
- Resolved catch types must derive from `Throwable`. Handler entry state now
  gives `move-exception` the common resolved caught type instead of always
  widening to `Throwable`.
- `check-cast`, `instance-of`, reflection instance checks, and typed exception
  dispatch use the same hierarchy. Known bad casts raise a typed
  `ClassCastException`, `throw null` produces `NullPointerException`, synthetic
  host failures are normalized to typed exception objects, and an unresolved
  external thrown value can reach `catch (Throwable)` without matching a
  speculative narrower catch.
- Ten new regressions bring MihonCompatKit to 113 passing tests, including 78
  interpreter tests and all eight pinned real-extension paths. The explicit
  compatibility build and KamiCore dependency build/test pass on Windows/Swift
  6.3.3; Swift CI, both iOS targets, and IPA packaging pass on the exact SHA.

Commit `f36a07a` subsequently completed parsed-DEX interface-default and
lexical class/interface `invoke-super` behavior. Broader resolution beyond the
parsed graph remains open.

## What the preceding exact-type continuation completed

Commit `10bf770` completes the exact primitive-family and uninitialized-object
portion of the DEX register verifier:

- The register lattice now follows ART's concrete type families: bounded
  polymorphic 32-bit constants; boolean, byte, char, short, int, and float;
  distinct long/double/constant-wide pairs; initialized references;
  allocation-site-specific uninitialized references; and uninitialized
  constructor `this`. Undefined and conflict states remain explicit.
- Numeric opcodes, comparisons, branches, arrays, fields, calls, returns, and
  conversions now require and produce their exact primitive family. Constants
  remain usable as int/float or long/double until an operation resolves them,
  matching the verifier behavior documented by ART's
  [`RegType`](https://android.googlesource.com/platform/art/+/master/runtime/verifier/reg_type.h).
- `new-instance` produces an allocation-identity value rather than an ordinary
  reference. Only object moves and the matching direct constructor call may
  consume that state; successful construction initializes every alias.
  Ordinary calls, fields, arrays, casts, monitors, throws, and returns reject
  uninitialized objects.
- Instance constructors receive uninitialized `this`, may access their own
  fields before the super/this call, and cannot return until a direct
  constructor call initializes all aliases. Constructor calls on already
  initialized references and constructor names invoked with the wrong opcode
  are rejected. These rules follow ART's
  [`MethodVerifier`](https://android.googlesource.com/platform/art/+/master/runtime/verifier/method_verifier.cc)
  model while retaining its permissive superclass-constructor behavior used by
  optimized DEX.
- Synthetic object fixtures now execute explicit constructors instead of
  relying on the interpreter's previous implicit initialized-reference state.
  Nine new regressions cover cross-family misuse, polymorphic constants,
  conversion outputs, alias initialization, premature constructor return,
  double initialization, and initialized/uninitialized joins.
- At that checkpoint MihonCompatKit passed 103 tests, including 68 interpreter
  tests and all eight pinned real-extension paths. The all-products debug build
  and the KamiCore dependency build/test also pass on Windows/Swift 6.3.3.

Commit `b079d69` subsequently completed resolved reference-hierarchy and
catch-type assignability. Remaining opcodes, broader external class resolution,
and differential AOSP fixtures remain issue #1 work.

## What the preceding register-category continuation completed

Commit `7ce3c81` adds bounded register-category verification and corrects the
interpreter's binary arithmetic opcode mapping:

- All structurally accepted instructions receive static register-bounds checks,
  even when unreachable. Exposed string, type, field, method, and prototype
  indexes are also checked before dataflow begins.
- Method parameters seed the final `ins_size` words from the exact prototype and
  receiver staticness. A bounded worklist propagates types over normal and
  exception edges, with deterministic switch/handler successor ordering.
- The lattice tracks undefined and conflicting values, the
  verifier-polymorphic zero, category-1 primitives, adjacent wide halves, and
  reference descriptors. Wide-pair halves are invalidated when clobbered.
- Moves, result/return forms, invokes, fields, arrays, branches, unary/binary
  operations, and literal operations require compatible categories before the
  interpreter runs. The per-method caps are 250,000 states, 8,000,000 register
  cells, and 8,000,000 merges.
- The new checks exposed a real semantic error in the interpreter's
  `0x90...0xcf` table. It now follows AOSP's operation/type-major ordering;
  BatCave's real `0x95` instruction executes as `and-int` instead of being
  misread as `sub-long` and silently coerced through defensive zero values.
- Eight focused register-verifier regressions and one binary-op ordering
  regression bring MihonCompatKit to 94 passing tests. All eight pinned
  real-extension paths still pass, and a clean KamiCore dependency build sees
  the new verifier source.

At that checkpoint, exact `int`/`float` and `long`/`double` distinctions,
uninitialized-instance constructor rules, resolved reference-hierarchy
assignability, and resolved catch-type assignability to `Throwable` remained.
Commit `10bf770` subsequently completed the primitive and constructor-state
portions; commit `b079d69` subsequently completed the resolved hierarchy and
catch-type portions.

## What the preceding exception-verifier continuation completed

Commit `66d4126` extends pre-execution verification through DEX exception data
and the related verifier-only control-flow rules:

- Exception-table decoding now throws on malformed data instead of silently
  treating the method as if it had no handlers. Verified, decoded `DexTryBlock`
  values are cached once per method and used directly during execution.
- The verifier requires zero try padding, nonempty and ordered non-overlapping
  try ranges on instruction boundaries, exact handler offsets, bounded 32-bit
  ULEB/SLEB encodings, valid catch type indexes/descriptors, and handler targets
  on executable instruction boundaries.
- Synthetic methods prove typed and catch-all handlers actually execute.
  Handler bodies may deliberately ignore the exception, matching current ART
  behavior rather than imposing an invalid `move-exception` requirement.
- AOSP verifier rules now reject zero-offset `goto`, `goto/16`, and conditional
  branches, invalid `move-result` placement or branch targets, invalid
  `move-exception` placement or ordinary control-flow entry, and insufficient
  `outs_size`. Zero-offset `goto/32` remains valid.
- Eleven focused regressions cover the new rules. All 85 MihonCompatKit tests,
  including all eight pinned real-extension paths, pass locally, and KamiCore
  still builds as a dependency.

At that checkpoint, strict exception-table geometry and decoding were complete,
while register-category dataflow and resolved catch-type assignability remained.
Commit `7ce3c81` subsequently added bounded category-level dataflow.

## What the preceding structural-verifier continuation completed

Commit `284b24d` adds a bounded, one-time structural verifier before a DEX
method can execute:

- It decodes the entire code item using the standard DEX instruction-width
  table and rejects invalid/reserved or truncated instructions, even on paths
  the interpreter would not take.
- Direct branches, ordinary fallthrough, and packed/sparse switch cases must
  land on exact executable instruction boundaries inside the code item.
- Packed-switch, sparse-switch, and array-data payloads must be aligned,
  complete, and referenced by the matching opcode family. Sparse keys must be
  strictly increasing and array-data widths must be 1, 2, 4, or 8 bytes.
- Code items are capped at 2,000,000 code units, and successful verification
  is cached once per method for the lifetime of an interpreter.
- Nine focused regressions cover valid packed-switch execution and malformed
  truncation, operand branches, payload case targets, fallthrough, alignment,
  family mismatches, sparse ordering, and array element widths. All 74 tests,
  including all eight pinned real-extension paths, pass locally.

This was structural geometry/control-flow verification, not a claim of a full
Dalvik verifier. Commit `66d4126` subsequently added strict exception-table and
handler validation.

## What the earlier request-model continuation completed

Commit `4d042c9` advances the pinned BatCave APK through transport-neutral
request construction without performing network I/O:

- Public, `Sendable`, equatable `CompatHTTPRequest`, header, form-field, body,
  and cache-policy values live in
  `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPRequest.swift`.
- The exact host allow-list now models the BatCave-reached OkHttp surface:
  per-source `NetworkHelper`/client identity, required default interceptors,
  client cloning, compression-interceptor setup, headers, HTTP(S) URLs, form
  and text bodies, cache control, request builders/getters, and inert calls.
- Request inputs are bounded: URLs are HTTP(S)-only and at most 8 KiB; header
  names/values reject invalid controls and CRLF injection; header/form
  collections and aggregate raw bytes are capped; text bodies are capped at
  1 MiB. These are construction limits, not a substitute for future response
  streaming limits.
- Kotlin duration unit fields and the exact duration conversions reached by
  cache-control setup are modeled. Compiler-only
  `SpillingKt.nullOutSpilledVariable` is also covered.
- `HostBridge.lastPreparedRequest` exposes only the inert request handed to
  `OkHttpClient.newCall`; it does not send it.
- The real BatCave `getPopularManga` assertion proves this exact request:

  ```text
  POST https://batcave.biz/comix/
  dlenewssortby=rating
  dledirection=desc
  set_new_sort=dle_sort_cat_1
  set_direction_sort=dle_direction_cat_1
  ```

- Execution then stops exactly at the deliberately unresolved method
  `Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;->awaitSuccess(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;`.
  This is the transport/coroutine boundary, not a successful popular-manga
  response.

The two focused request tests and eight pinned real-extension tests are part
of the 63-test MihonCompatKit suite at that historical baseline. All three
workflows linked above passed for that exact implementation SHA.

## What the earlier runtime continuation completed

Commit `05720d2` advances the same pinned BatCave APK from shallow getters to a
reproducible pre-request execution path:

- DEX and host methods are keyed by exact declaring class, name, parameter
  descriptors, return descriptor, and static/instance kind. Name-only public
  calls reject overload ambiguity.
- Invoke validation checks register-word counts, wide pairs, caller
  `outs_size`, logical argument categories, return categories, and encoded
  static/instance consistency. Diagnostics and traces carry canonical method
  signatures.
- DEX class initialization runs once before static use/allocation, initializes
  DEX superclasses first, retains failure state, and shares the entry call's
  instruction budget.
- The deny-by-default host surface now includes only exact signatures proven by
  synthetic or pinned-corpus paths: confined source-field reflection, core
  Kotlin result/lazy/pair/coroutine primitives, primitive boxes, atomics,
  bounded collections and iteration, regex/date construction, and Mihon
  filters.
- `compat-audit methods <apk> [text-or-index]` prints canonical first-DEX
  method identities, making each next missing ABI call reproducible.
- BatCave's real constructor succeeds. Its real `getPopularManga` path crossed
  filters and iteration to the former `FormBody.Builder` boundary; commit
  `4d042c9` subsequently completed the pure request layer described above.

## What Phase 2 completed

The range from `6f9de07` through `4e50e63` contains these checkpoints:

```text
743690d fix: repair CI compilation and preserve library state
28f9430 fix: resolve macOS package diagnostics
b88cf79 fix: handle invalid extension indexes in app
60daa81 fix: execute real extension dex correctly
270843d fix: harden untrusted extension parsing
9fb7d87 fix: surface oversized repository responses
1ae9e14 docs: record measured runtime and CI status
4e50e63 docs: align architecture with runtime status
```

The work includes:

- SQLite binding/step error handling and preservation of manga library state,
  chapter IDs, read state, bookmarks, and progress during refreshes.
- Correct DEX 35c register ordering, final-register argument placement, shared
  call-tree budgets, call-depth limits, exceptions, additional opcode
  families, Java numeric behavior, and bounds-safe host arguments.
- Minimal Object, String, StringBuilder, Kotlin Intrinsics, HttpSource, and
  ParsedHttpSource construction surfaces.
- Bounded ZIP/ZIP64, DEFLATE, zlib, gzip, AXML, protobuf, and DEX parsing with
  checksums, structural checks, count/size limits, and malformed-prefix tests.
- Repository index limits, typed missing-response errors, and an APK response
  acceptance limit.
- Immutable, SHA-256-locked real APK tests in Swift CI.
- Honest documentation of the measured M1 runtime rather than claiming full
  extension compatibility.

The current DEX parser accepts formats 035 and 037 through 040. Format 036 is
not a standard supported revision, and 041 is deliberately rejected because
its container/header contract differs from the implemented 112-byte format.

## What is proven, and what is not

Proven today:

- Real store-index parsing for protobuf and legacy JSON formats.
- Bounded APK archive, manifest, and DEX structural parsing.
- Compatibility analysis and the `compat-audit` CLI.
- Deterministic, non-executing structural plans for the six current lib 1.6
  execution profiles, explicit blockers for legacy/unsupported shapes, and
  directory reporting that preserves later results after per-file errors. This
  is shape discovery only, not authentication, admission, or runtime proof.
- Committed corpus evidence locks and vendors 27 artifacts in 8 execution, 13
  measurement-only current lib 1.6, and 6 AOSP conformance roles. Baozi,
  TuttoAnimeManga, and Mangas-Origines.fr are in the execution role; the remaining measurement set is still parsed and
  statically audited only. Its membership does not grant signer trust,
  admission, installation, DEX execution, or compatibility proof.
- Exact execution of the pinned constructors/getters listed above and
  BatCave's interpreted popular, paginated text-search, latest-updates, and core
  details plus combined chapter-update and page-list paths through exact request
  construction, bounded async response delivery, production selectors,
  generated DTO encoding/decoding, and exact compatibility-model conversion.
- The locked Kawii Manga profile independently exposes metadata, popular,
  latest, text search, combined details/chapters, and pages through its real
  stable public wrappers, exact JSON requests, and custom source header.
- The locked MangaMelon profile independently exposes metadata, popular,
  latest, static `Sort`/`Select` filtered search, combined details/chapters,
  memo propagation, and ordered pages through exact Base64 form requests.
- The locked Baozi Manhua 1.6.29 profile independently exposes metadata,
  popular, latest, text search, the exact header-plus-four-`Select` filter
  schema, combined details/chapters, and pages through deterministic HTML
  fixtures. Its exact DEX `imageRequest(Page)` rewrites the CDN host in the
  fixture and returns a bounded `ImageRequest` without network I/O.
- The locked TuttoAnimeManga 1.6.10 profile independently exposes metadata,
  popular, latest, text search, details, combined chapters/update, chapter list,
  pages, and inherited page-image headers through exact GET requests and bounded
  JSON conversion. Its latest path filters null chapters, sorts raw timestamps,
  and limits results to ten. This evidence uses deterministic responses and is
  not a live-site or PizzaReader-family compatibility claim.
- The locked Mangas-Origines.fr 1.6.58 profile independently exposes metadata,
  an exact seven-entry static filter graph, popular, latest, text and filtered
  search, details, chapters, pages, and inherited page-image headers through
  exact POST/GET requests and bounded HTML conversion. Altered filters and
  unexpected preferences fail before transport. This evidence is deterministic
  and does not claim current live-site availability.
- The locked BatCave, Kawii, MangaMelon, Baozi, Tutto, and Mangas-Origines.fr profiles expose their
  measured operations through `KamiSource`; source-scoped actor ownership
  serializes VM entry, and KamiCore's existing registry accepts an admitted
  measured source.
- `ReaderView` asynchronously resolves one `ImageRequest` per page after the
  page list and forwards its URL/headers to `ReaderImagePipeline`.
- Repository and APK persistence, repository-key or explicit-user first trust,
  install/update and enable/disable UI, startup exact-file re-authentication,
  capability-only source construction, failure-to-disabled behavior, and active
  downloaded-source display in Browse.
- Source-scoped, bounded OkHttp request/response/body/Okio values, async nested
  frame resumption, cancellation, typed transport/HTTP errors, the exact pinned
  BatCave POST assertion, and a deterministic no-live-network test transport.
- Bounded pre-execution verification of complete instruction geometry,
  try/catch tables, register operands, resolved catch classes, and exact
  primitive/constructor/reference register dataflow over normal and exception
  edges.
- Native MangaDex browsing through the existing `KamiSource` implementation;
  the app starts with it and can add a supported authenticated downloaded source.
- Simulator/device compilation and creation of a real unsigned IPA.

Not proven or implemented:

- A general downloaded-extension-to-`KamiSource` bridge beyond the exact
  BatCave, Kawii, MangaMelon, Baozi, Tutto, and Mangas-Origines.fr profiles, dynamic/network-backed filter
  lists, or arbitrary custom image-request behavior beyond the bounded
  source-scoped execution capability.
- Baozi's bounded scalar preferences are accepted by the exact profile and
  exercised by the runtime tests, but the production app has no preference UI
  or persistence path. App construction explicitly defaults
  `BAOZI_BANNER=0` because modes 1/2 require unavailable Bitmap operations;
  callers can still provide an explicit preference set.
- Baozi's source operations and supported reader requests execute its
  configured bounded OkHttp surfaces. The direct-302 reader fixture proves the
  retained redirect-domain tag, and the GET-only single-exchange fixture proves
  that the rewritten location drives a bounded follow-up to final bytes with
  network interceptors on each exchange. Banner cropping, ordinary
  source-operation response sequences, and non-GET follow-up remain unsupported.
- Broad Jsoup coverage beyond the measured subset, kotlinx serialization beyond
  the bounded generated encoder/decoder slice,
  persistent source preferences and cookies, rate limiting, automatic complete
  execution-plan generation/admission beyond the bounded structural candidate,
  or WebView challenge handling. The current cookie jar is
  source-isolated but in memory.
- Full DEX opcode coverage or complete hierarchy behavior when class data leaves
  the parsed DEX and bounded host graph. Structural
  code-item/control-flow/exception-table verification, exact
  primitive/constructor/reference register verification, resolved `Throwable`
  catch validation, runtime cast/catch checks, receiver-directed virtual/class
  dispatch, maximally specific interface defaults, and lexical class/interface
  `invoke-super` across parsed DEX graphs are working. Equivalent resolution
  across incomplete external hierarchy data remains open.
- Automatic safe profile admission beyond the six-entry exact catalog.
- A signed installation on a physical iPhone or iPad.
- App-facing Diagnostics/file export/share or a final distribution/licensing
  model.

Do not generalize the six pinned adapters into broad extension support.

## Security and trust boundary

A completed security review of the executable seven-commit Phase 2 diff found
no vulnerability introduced or newly made reachable by that range. That result
does not mean the runtime is production-complete.

Preserve these security facts:

- Repository indexes, redirects, APKs, ZIP/AXML/protobuf/DEX structures, DEX
  bytecode, source responses and their JSON, and backup data are hostile input.
- Interpreted code may reach native capabilities only through explicit,
  deny-by-default `HostBridge` registrations.
- Checksums and locked hashes detect corruption or substitution relative to a
  known fixture; publisher identity comes only from the cryptographically
  verified APK certificate plus persisted repository/user trust. Measurement
  release signature checks are parser conformance only; corpus membership never
  supplies that trust or an admission capability.
- Never restore a general `SourceRegistry.add`. Pinned compiled adapters use
  `addPinned`; downloaded adapters must use `addDownloaded` with an
  `ExtensionAdmission` issued and persisted by `ExtensionAdmissionService`.
- Keep `ExtensionSourceFactory` as the only admission-capability consumer. It
  must authenticate the exact bounded buffer supplied to a measured profile;
  startup restoration must disable a record that cannot be re-authenticated.
- Preserve update monotonicity, same-version byte equality, and verified
  single-signer lineage or exact multi-signer continuity.
- Never load Android native `.so` files.
- Keep cookies, preferences, network policy, and future WebView state scoped
  to one source; do not expose app-global secrets to interpreted code.
- Preserve shared instruction/call-depth/array limits when adding opcodes.
- SQL values must remain parameter-bound and all persistence must remain
  actor-serialized and transactional.

Known pre-existing hardening gaps that were not diff-introduced findings:

- Native repository index/APK downloads still need broader streaming and
  aggregate resource accounting. The extension compat transport now enforces
  its own response-body cap while delegate bytes arrive.
- External-list/APK URL scheme, redirect, and destination policy is broad.
- ZIP/DEX/string processing lacks a complete aggregate resource budget.
- External class relationships absent from both the APK and bounded host graph
  remain deliberately unresolved; wider runtime resolution is required for
  exact casts and narrower typed catches across that boundary.
- Receiver-directed virtual lookup, interface-default selection, and lexical
  class/interface `invoke-super` are exact within parsed DEX graphs; complete
  resolution across hierarchy data that leaves the parsed DEX remains open.
- Instruction counts do not price expensive StringBuilder copying or every
  allocation/host-collection operation cost.

Address these before treating arbitrary downloaded extensions as safe.

## Open work and issue tracker

| Priority | Issue | Purpose |
|---|---|---|
| P0 | [#1 Complete DEX opcode coverage and verifier semantics](https://github.com/taizaki69/Kami/issues/1) | Remaining external hierarchy and super/default resolution, opcode, and differential semantics work |
| Completed | [#2 Build the first end-to-end interpreted Mihon source](https://github.com/taizaki69/Kami/issues/2) | Exact pinned BatCave profile completed at `3708aa1`; general compatibility remains separate work |
| Completed | [#3 Verify APK signing identity](https://github.com/taizaki69/Kami/issues/3) | v1/v2/v3 verification and persisted admission completed at `a902d06`; the later install/restore/factory product path is complete at `4d42def` |
| Diagnostics (partial product surface) | [#4 Add privacy-safe compatibility telemetry](https://github.com/taizaki69/Kami/issues/4) | Typed stage-counted reports/static ranking began at `e56bd9a`; `b1cd246` adds below-catch first-gap capture, fail-closed exact external fields, caught-bridge coverage, and deterministic regression promotion. App-facing user-selected export/share remains |
| Distribution | [#5 Choose Kami's distribution and licensing model](https://github.com/taizaki69/Kami/issues/5) | Preserve all options; do not add a project license without an explicit owner decision |

The rest of the product backlog is in `TODO.md`.

## Recommended next implementation sequence

1. Use the completed first-gap evidence and `compat-audit promote-gap` tooling
   to promote Komikcast, the next evidence-ranked authenticated locked
   structural candidate, through exact construction, operations, app admission,
   and regression coverage. Its 42 statically unregistered surfaces are only a
   prioritization signal; never infer execution from that count.
2. Add issue #4's app-facing user-selected report export/share flow while
   preserving the same local-only redaction contract.
3. Add production preference UI and persistence for the exact bounded scalar
   preference model; keep app-global state out of interpreted code.
4. Keep Baozi banner cropping unsupported until there is a bounded portable
   pixel/JPEG implementation; a metadata-only bitmap shim is not compatibility.
5. Generate future catalog records from authenticated structural plans and
   measured capability evidence instead of hand-copying entry/wrapper
   structure. Unknown artifacts must still fail closed until their signer,
   declared source IDs, required host surface, and core operations have
   independently passed the admission policy.
6. Continue issue #1 with broader external hierarchy and super/default
   resolution, remaining opcodes, and differential AOSP coverage. Code-item
   geometry, strict try/catch decoding and resolved `Throwable` validation,
   branch/move-result/move-exception rules, bounded exact
   primitive/constructor/reference dataflow, runtime casts/catches,
   receiver-directed virtual/interface-default lookup, lexical parsed-DEX
   `invoke-super`, and invoke word-count/kind checks are already in.
7. Complete reader chapter transitions, then add iPad spreads, fit/crop
   controls, memory-pressure purging, and download-cache integration without
   weakening image limits.
8. Add aggregate parser/runtime resource accounting and streaming or
   delegate-limited repository downloads.
9. Profile the reader on a physical iPhone/iPad with large webtoon chapters and
   smoke-test a user-signed build; CI intentionally remains unsigned.

Every new runtime capability should arrive with a synthetic malformed fixture,
an exact real-APK assertion when reachable, and CI coverage.

## Important files

| Area | Entry point |
|---|---|
| Current status | `README.md`, `TODO.md`, `ARCHITECTURE.md` |
| Build and signing | `BUILDING.md`, `docs/IPA_BUILD.md`, `project.yml` |
| Runtime contract | `docs/EXTENSION_RUNTIME.md` |
| Measured compatibility | `docs/EXTENSION_COMPATIBILITY_MATRIX.md` |
| APK and archive parsing | `Packages/MihonCompatKit/Sources/MihonCompatKit/APK/` |
| DEX parser | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/DexFile.swift` |
| Interpreter | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexInterpreter.swift` |
| Structural plan discovery | `Packages/MihonCompatKit/Sources/MihonCompatKit/Sources/InterpretedExtensionPlan.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/InterpretedExtensionPlanTests.swift`, `Packages/MihonCompatKit/Sources/CompatAudit/AuditMain.swift` |
| Compatibility diagnostics | `Packages/MihonCompatKit/Sources/MihonCompatKit/Sources/InterpretedCompatibilityDiagnostics.swift`, `Packages/MihonCompatKit/Sources/MihonCompatKit/Analyzer/InterpretedCompatibilityAudit.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/InterpretedCompatibilityDiagnosticsTests.swift`, `Packages/MihonCompatKit/Sources/CompatAudit/AuditMain.swift` |
| Pinned app-facing source | `Packages/MihonCompatKit/Sources/MihonCompatKit/Sources/PinnedInterpretedSource.swift` |
| Method resolution | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexMethodResolver.swift` |
| Register/invoke verifier | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/DexRegisterVerifier.swift` |
| Native capability boundary | `Packages/MihonCompatKit/Sources/MihonCompatKit/Dex/Runtime/HostBridge.swift` |
| Pure HTTP request values | `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPRequest.swift` |
| Source-scoped HTTP transport | `Packages/MihonCompatKit/Sources/MihonCompatKit/Networking/CompatHTTPTransport.swift` |
| Request-model regressions | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/CompatHTTPRequestTests.swift` |
| Async VM/response regressions | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/AsyncInterpreterTests.swift` |
| HTML compatibility and limits | `Packages/MihonCompatKit/Sources/MihonCompatKit/HTML/CompatHTML.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/HTMLCompatibilityTests.swift` |
| Real APK execution frontier | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/RealExtensionExecutionTests.swift` |
| End-to-end adapter proof | `Packages/MihonCompatKit/Tests/MihonCompatKitTests/PinnedInterpretedSourceTests.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/KawiiMangaInterpretedSourceTests.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/MangaMelonInterpretedSourceTests.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/BaoziManhuaInterpretedSourceTests.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/TuttoAnimeMangaInterpretedSourceTests.swift`, `Packages/MihonCompatKit/Tests/MihonCompatKitTests/MangasOriginesFRInterpretedSourceTests.swift`, `Packages/KamiCore/Tests/KamiCoreTests/ExtensionSourceFactoryTests.swift` |
| Filtered Browse UI | `App/Sources/BrowseView.swift`, `App/Sources/SourceFilterSheet.swift` |
| Browse request routing | `Packages/KamiCore/Sources/KamiCore/Sources/SourceBrowseRequest.swift`, `Packages/KamiCore/Tests/KamiCoreTests/SourceBrowseRequestTests.swift` |
| Native reader UI | `App/Sources/ReaderView.swift`, `ReaderPageImage.swift`, `ReaderSettingsSheet.swift`, `docs/READER.md` |
| Reader settings/image boundary | `Packages/KamiCore/Sources/KamiCore/Models/ReaderSettings.swift`, `Packages/KamiCore/Sources/KamiCore/Services/ReaderImagePipeline.swift`, `Packages/KamiCore/Tests/KamiCoreTests/ReaderSupportTests.swift` |
| Repository client | `Packages/MihonCompatKit/Sources/MihonCompatKit/Repository/ExtensionRepository.swift` |
| App source seam | `Packages/MihonCompatKit/Sources/MihonCompatKit/Models/CompatModels.swift` (`KamiSource`) |
| Persistence | `Packages/KamiCore/Sources/KamiCore/Database/` |
| Corpus lock/fetch | `Tests/corpus/manifest.json`, `scripts/fetch_corpus.sh` |
| Workflows | `.github/workflows/ci.yml`, `ios-build.yml`, `ipa.yml` |

## Before pushing the next implementation

Run the checks appropriate to the active computer, then inspect the diff:

```bash
git diff --check
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
git status --short --branch
```

For app changes, also generate and compile both Simulator and unsigned generic
device targets on macOS. After pushing, require Swift CI, iOS Build, and IPA
Package to finish successfully for the exact head SHA.
