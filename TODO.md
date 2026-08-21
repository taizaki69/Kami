# Kami — Task Tracker

Legend: `[ ]` not started · `[~]` in progress · `[x]` complete · `[!]` blocked

## P0 — Extension research & foundation

- [x] Verify current ecosystem: tachiyomix 1.6/1.7 API, manifest keys, index
      formats (proto + legacy JSON), backup protobuf schema —
      `docs/EXTENSION_COMPATIBILITY_ANALYSIS.md`
- [x] Repository scaffold: SwiftPM packages + xcodegen spec + scripts
- [x] ZIP reader + DEFLATE/zlib/gzip decompressor (pure Swift), 5/5 tests
- [x] Binary Android XML (AXML) manifest parser — validated on real APK
- [x] DEX structural parser — validated on real APK (counts match reference)
- [x] Extension store client: `index.pb` + `index.min.json` + gzip unwrap +
      external-list indirection — validated against live Keiyoushi index
      (1372 extensions parsed)
- [x] Backup reader for legacy (zlib) `.tachibk` + proto schema decode
- [x] `compat-audit` CLI (inspect/missing/index) — run on 3 real APKs

## P0 — App foundation

- [x] Domain models + SQLite store with migrations + history/read-state
      preservation tests (run on macOS; code complete)
- [x] Native MangaDex source (popular/latest/search/details/chapters/pages)
- [x] SwiftUI app: Library / Browse / MangaDetail / Reader (paged) /
      Extensions (repo add via store client) / History / Updates placeholders
- [x] Reader progress + history persistence wired

## P0 — End-to-end extension execution (the honest frontier)

- [ ] DEX interpreter core M1 (frames, opcodes, object model, budgets)
- [ ] Kotlin/Java class library M2 — priority list measured in the matrix
- [ ] tachiyomix API bridge M3 (`HttpSource` → `KamiSource`)
- [ ] First real extension executing popular→search→details→chapters→pages
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

## Blocked / needs macOS

- [!] iOS app compile + simulator run + IPA packaging (scripts ready;
      requires Xcode — this repo was authored on Windows where the compat
      kit was fully built and tested instead)
