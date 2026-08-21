# Extension Runtime — Staged Plan and Honest Status

## Where we are

The compatibility pipeline is implemented and verified against real
extensions **up to DEX analysis**. Execution has not started. This document
is the engineering plan for the runtime and is deliberately honest about the
size of the remaining work.

## Architecture

```
Extension APK                       (untrusted)
   ↓ ZipArchive + Inflate           ✅ done
AndroidManifest.xml (AXML)          ✅ done — source class discovery
classes.dex                         ✅ done — structural parse
   ↓ DexInterpreter                 ◻ M1
   ↓ Kotlin/Java class library      ◻ M2 (the long tail)
   ↓ tachiyomix API bridge          ◻ M3
KamiSource (Swift protocol)         ✅ exists (native sources use it today)
   ↓ SourceRegistry                 ✅ exists
App UI / database                   ✅ exists
```

The interpreter is fed by the already-parsed tables (`DexFile` keeps the raw
`insns` via `codeItem`). Bridged sources register in `SourceRegistry`, so the
app layer never learns whether a source is native or interpreted.

## Milestones

### M1 — Interpreter core (pure Swift)
- Frame/registers, invoke stack, all Dalvik opcodes used by Kotlin output
  (the full set is ~220 opcodes; Kotlin 2.x emits a stable subset).
- Value model: null/i32/i64/f32/f64/object-ref; object model with arrays,
  strings (MUTF-8↔Swift), field storage.
- Verification: run against methods disassembled from corpus APKs, output
  compared with expected traces produced by `dx`/`d8` on reference projects.
- Guardrails per mission §28: instruction budget (runaway-loop kill),
  per-extension error isolation (interpreted code cannot crash the process —
  it can only throw), API bridge allow-list.

### M2 — Class library (driven by `compat-audit`)
Real measured priority (see EXTENSION_COMPATIBILITY_MATRIX.md):
1. `java.lang` core: String, StringBuilder, Integer/Long/Float, Math, Object.
2. Kotlin stdlib surface: CollectionsKt, StringsKt, `let/run/also`, ranges,
   lazy, `toMutableList`, etc. (compiled to static calls — no magic).
3. `java.util`: ArrayList, HashMap, Arrays, regex (`java.util.regex` — the
   heaviest single item; candidates: backport a Thompson NFA engine with
   Java semantics, or wrap `NSRegularExpression` where semantics align).
4. `kotlinx.serialization` JSON (many sources parse JSON responses).
5. OkHttp bridge → URLSession-backed compat client (request building,
   headers, form/JSON bodies, cookies, interceptors subset).
6. Jsoup bridge → Swift HTML parser with Jsoup-compatible selector semantics
   (`select`, `selectFirst`, `attr`, `text`, `ownText`, `absUrl`, baseUri).
7. `android.content.SharedPreferences` → UserDefaults-backed per-source store.
8. `androidx.preference` constructors → no-op objects consumed by the
   preference-screen bridge; Kami renders its own UI from calls made.
9. Coroutines: **the hard part.** Kotlin compiles suspend functions to CPS
   state machines using `kotlin.coroutines.intrinsics`. Plan: implement the
   `Continuation` protocol with Swift continuations bridging into async/await,
   plus `withContext`/dispatcher shims.

### M3 — tachiyomix API bridge
Swift implementations of `HttpSource`, `SManga.create()`, `SChapter.create()`,
`MangasPage`, `Filter`, `NetworkHelper`, `JsoupExtensions` — mapped onto the
`KamiSource` protocol. The bridge owns per-source OkHttp-compatible clients,
rate limits, and cookie jars.

### M4 — WebView/Cloudflare bridge
`WKWebView` per-source sessions; challenge detection (403/503 + cf-mitigated
cookies), cookie + User-Agent sync back into the compat network stack, retry
of the failed request. No bypass claims — user-solved challenges only.

## What will realistically not work
- Extensions embedding native `.so` libraries (rare in the corpus).
- Sources requiring wide Android UI framework surface (also rare; most use
  only preferences).
- Anything depending on executing downloaded native code — prohibited by iOS.

## Effort estimate
M1 is a focused engine task (weeks). M2 is the multi-quarter long tail, but
`compat-audit` measurements show the workload concentrates: ~20 classes cover
the bulk of references in the sampled corpus. Each compat class lands with
regression tests per mission §38.
