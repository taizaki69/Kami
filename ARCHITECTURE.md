# Architecture

Kami is three layers with hard boundaries. Compatibility hacks live in
MihonCompatKit, never in the app.

```
┌──────────────────────────────────────────────┐
│ App (SwiftUI, iOS 17+)                       │
│  RootTab: Library/Updates/History/Browse/    │
│  Extensions · Reader · MangaDetail           │
└──────────────┬───────────────────────────────┘
               │ KamiSource protocol (async)
┌──────────────┴───────────────────────────────┐
│ KamiCore                                     │
│  Models · LibraryStore (actor, SQLite)       │
│  SourceRegistry · LibraryService             │
│  Native sources: MangaDex                    │
└──────────────┬───────────────────────────────┘
               │ SMangaCompat/SChapterCompat/PageCompat
┌──────────────┴───────────────────────────────┐
│ MihonCompatKit (pure Swift, no Apple-only    │
│ frameworks — builds on iOS/macOS/Linux/      │
│ Windows)                                     │
│  APK: ZipArchive · Inflate · BinaryXML       │
│  Dex: DexFile + bounded M1 interpreter       │
│  Repository: index.pb/index.min.json client  │
│  Backup: TachibkReader                       │
│  Analyzer: ExtensionAnalyzer + compat-audit  │
└──────────────────────────────────────────────┘
```

## Key decisions

- **`KamiSource` is the seam.** Native sources and future app-integrated
  DEX-bridged sources implement the same protocol; the registry hides which
  is which.
  The protocol mirrors tachiyomix semantics (popular/latest/search/details/
  chapters/pages + image requests with headers) so the bridge is 1:1.
- **Compat kit stays host-portable.** No UIKit/Combine/URLSession-only APIs
  without `#if canImport` guards. This is what allowed real verification on
  Windows during development and keeps the parsers unit-testable anywhere.
- **One database actor.** All persistence goes through `LibraryStore`
  (SQLite, WAL, versioned migrations). Views never see SQL.
- **Untrusted code boundary.** Extension APKs are data until the interpreter
  runs them; even then they only reach iOS capabilities through explicit
  bridges (HTTP, preferences, cookies, WebView) with budgets and isolation
  (EXTENSION_RUNTIME.md M1 guardrails).
- **xcodegen, not a committed pbxproj.** `project.yml` is the source of
  truth; generated per-machine. Keeps diffs clean and remerges trivial.

## Concurrency model
- UI: SwiftUI + `@MainActor` observable models.
- Sources: async/await throughout; every source call is cancellable.
- Persistence: actor-serialized SQLite.
- Interpreter: the M1 runtime has a shared instruction budget and call-depth
  guard today. A dedicated executor and suspend-method bridging via Swift
  continuations remain follow-up work.
