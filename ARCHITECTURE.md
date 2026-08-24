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
│  ExtensionInstallationService                │
│  ExtensionAdmissionService                   │
│  ExtensionSourceFactory · SourceRegistry     │
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
│  Sources: measured interpreted profiles      │
│  Repository: index.pb/index.min.json client  │
│  Backup: TachibkReader                       │
│  Analyzer: ExtensionAnalyzer + compat-audit  │
└──────────────────────────────────────────────┘
```

## Key decisions

- **`KamiSource` is the seam.** Native sources and the pinned BatCave, Kawii, and MangaMelon
  Manga DEX-backed sources implement the same protocol; the registry hides
  which is which. Future profiles must preserve this boundary.
  The protocol mirrors tachiyomix semantics (popular/latest/search/details/
  chapters/pages + image requests with headers) so the bridge is 1:1.
- **Compat kit stays host-portable.** No UIKit/Combine/URLSession-only APIs
  without `#if canImport` guards. This is what allowed real verification on
  Windows during development and keeps the parsers unit-testable anywhere.
- **One database actor.** All persistence goes through `LibraryStore`
  (SQLite, WAL, versioned migrations). Views never see SQL.
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
  selects an exact measured profile, and verifies every runtime source ID was
  declared by the repository. Measured profiles route stable public source API
  wrappers from either the generated entry class or its local superclass chain;
  startup failures and unmeasured profiles are disabled rather than run.
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
  guard. Each app-facing interpreted source actor owns one mutable VM and uses
  a bounded cancellation-aware queue to prevent overlapping entry across
  suspend-method continuations.
