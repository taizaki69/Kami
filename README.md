# Kami

A native iOS manga reader with a Swift runtime for measured Mihon/Tachiyomi
extension APKs. Created and maintained by
[taizaki69](https://github.com/taizaki69).

## Current scope — 2026-10-04

Kami includes a native MangaDex source, a persistent library, history and
reading progress, source browsing and filters, and an LTR/RTL/webtoon reader
with previous/next chapters, zoom, bounded image prefetch and retry. Categories
can be created, renamed, reordered and deleted, assigned individually or in
bulk, and combined with library search. Deleting a category preserves manga,
chapter progress and history; bulk changes preserve untouched memberships.

Updates can check the saved library on demand, report progress and per-manga
failures or skipped sources, and cancel while keeping completed results.
The first successful chapter list establishes a baseline; later discoveries
appear in a persistent, paginated feed grouped by day and manga. Missing
chapters retain their reading state and history if they return. History and
Updates open the current saved chapter at its stored reading position.
Checks use enabled source registrations, with at most three sources in
parallel and one manga at a time per source. They do not run automatically in
the background. Native MangaDex requests share the bounded, cancellable HTTP
transport and reject HTTP failures and incomplete chapter catalogs.

The [download manager](docs/DOWNLOADS.md) queues selected library chapters for
foreground transfer and persists progress and failures. Paused or interrupted
chapters retry from the beginning. Completed chapters open locally with their
saved reading progress even when the source is disabled or absent. Local reads
verify their files and never silently fall back to network. Deleting a download
preserves chapter progress and history; an open reader retains its files until
it closes. Source changes invalidate unfinished attempts before publication.

Library → Library options → Library backups prepares a native
[Kami backup](docs/NATIVE_BACKUPS.md) and saves it through Files. It includes all
saved manga, categories, chapter state, full history and discovery records,
including manga outside the library and hidden chapters. Downloaded pages,
extension installations and settings are excluded. Restoration is not available
in this version; the export screen states that limitation.

The [Mihon backup decoder](docs/BACKUP_COMPATIBILITY.md) reads bounded gzip/raw
protobuf into typed library records and reports unsupported fields. Kotlin
reference fixtures check producer defaults, exact 64-bit identities, category
orders, chapters and history. Immutable restore preview, atomic database merge,
source mapping and import UI remain pending for native and Mihon archives.

Extension installation authenticates the exact APK hash, package/version,
signer and declared source IDs. Repository trust or explicit certificate
confirmation is persisted and checked again at startup. The source factory
re-authenticates the immutable bytes it executes and accepts only an exact
measured profile. The APK corpus is a set of test fixtures, never permission
to install or execute arbitrary extensions.

The current lib 1.6 profile catalog contains:

| Profile | Exact version |
|---|---|
| BatCave | 1.6.9 |
| Kawii Manga | 1.6.1 |
| MangaMelon | 1.6.1 |
| Baozi Manhua | 1.6.29 |
| TuttoAnimeManga | 1.6.10 |
| Mangas-Origines.fr | 1.6.58 |
| Komikcast / VoraToon | 1.6.83 |
| Yomu Comics / SSSCanlator | 1.6.59 |
| EternalMangas | 1.6.28 |
| DocTruyen3Q | 1.6.38 |
| FoolSlide Customizable | 1.6.6, requires a configured HTTPS source URL |

These profiles are backed by deterministic real-APK tests with injected
responses. Their evidence does not establish live-site availability,
Cloudflare handling, arbitrary extension-family compatibility, or compatibility
with newer APK versions. See the
[compatibility matrix](docs/EXTENSION_COMPATIBILITY_MATRIX.md) for operation
scope and the [runtime design](docs/EXTENSION_RUNTIME.md) for the host boundary.

FoolSlide's raw default URL is a loopback placeholder. The downloaded-source
factory requires a configured HTTPS URL; an unconfigured installation stays
inactive. Its settings form saves the URL and adult-content confirmation for
the authenticated 1.6.6 APK. Saving a disabled extension keeps it disabled;
enabling it is a separate choice. Settings survive restarts and disabling.
Changing the website is blocked once any manga from this source has been
stored, including manga outside the library. Replacing or disabling a source
revokes its old requests and refreshes open browse/reader sessions.
Baozi's unsupported Android bitmap banner transform remains disabled by the
factory default, including when a partial raw preference set omits that mode.
Other profiles do not yet expose product settings.

The compatibility layer includes bounded ZIP/DEFLATE, Android manifest and DEX
parsers, APK signature verification, a verified interpreter subset, isolated
HTTP transport, bounded HTML/JSON/model bridges and typed compatibility
diagnostics. Static gaps guide work; a smaller gap count does not prove that
more source operations execute. Regex worst-case execution time, the broader
Kotlin/Java/Android API surface, arbitrary dynamic filters and general Android
image transforms remain open.

The lock contains 27 artifacts: eleven exact current execution profiles, two
legacy constructor fixtures, eight measurement-only APKs, and six AOSP signing
conformance fixtures. Historical paths under `measurement/` are retained; the
manifest's `role` field determines measurement membership. Source acquisition
provenance, fixture hashes and separate third-party notices are preserved.

Background downloads, scheduled background updates, backup restore and migration, further
source settings, Cloudflare cookie bridging, iPad spreads and physical-device performance verification
remain on the [task tracker](TODO.md). The broader daily-reader and extension
compatibility objective is still in progress.

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

## Portable development and verification

On Linux, use Swift 6.3.3 and the checked-in helper. `KAMI_SWIFT` can select an
installed Swift executable and `KAMI_JOBS` controls parallelism (6 by default).

```bash
./scripts/linux-dev version
bash scripts/fetch_corpus.sh
./scripts/linux-dev test
./scripts/linux-dev audit gaps Tests/corpus --role measurement
```

The role-selected audit validates the manifest and each selected APK's hash
before static analysis. It does not execute or admit an extension. Windows
continues to use `scripts/windows_dev_test.bat` for the portable packages.

[Current verification](docs/VERIFICATION-2026-10-04.md) and the
[earlier record](docs/VERIFICATION-2026-10-03.md) separate Linux package
results, SQLite persistence coverage, deterministic audits and Apple workflows
for the implementation commit. Linux success is not an iOS build or interaction
test. Simulator/device compilation and the unsigned IPA use the existing Apple
workflows; physical-device behavior remains unverified. Historical checkpoint
counts and workflow links are retained in [HANDOFF.md](HANDOFF.md).

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
