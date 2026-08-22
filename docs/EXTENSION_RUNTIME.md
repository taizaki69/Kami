# Extension Runtime — Measured Status and Staged Plan

**Last updated:** 2026-08-22

## Where we are

Kami has crossed from DEX analysis into controlled execution. The partial M1
interpreter runs synthetic conformance fixtures and progressively deeper paths
from three pinned, current Mihon extension APKs. It is not yet a complete
verifier, Java or Kotlin runtime, network bridge, or end-to-end source
implementation.

Measured real-APK behavior today:

- Akuma 1.4.10, MangaDex 1.4.212, and BatCave 1.6.9 entry constructors return
  real DEX objects.
- BatCave 1.6.9 returns its real base URL, language, name, and 64-bit source ID.
- BatCave's real `getPopularManga` path executes class initialization, Kotlin
  pairs and collections, Mihon filters and iteration, and synchronous coroutine
  setup before stopping at the exact unimplemented OkHttp form-body builder:
  `FormBody.Builder.<init>(Charset, int, DefaultConstructorMarker)`.
- No test claims a completed popular/search request, details, chapters, pages,
  HTTP transport, HTML parsing, JSON serialization, preferences, or Cloudflare
  behavior yet.

## Architecture

```text
Extension APK                       (untrusted)
   ↓ bounded ZIP/DEFLATE + CRC      working
AndroidManifest.xml (AXML)          working
classes*.dex                        validated structural parse
   ↓ DexInterpreter                 partial M1; measured real paths execute
   ↓ Java/Kotlin HostBridge         partial exact-signature M2 surface
   ↓ tachiyomix API bridge          not implemented
KamiSource (Swift protocol)         working for native sources
   ↓ SourceRegistry / app / DB      working
```

The interpreter consumes `DexFile` code items directly. It follows the Android
DEX instruction formats and bytecode semantics documented by AOSP:

- https://source.android.com/docs/core/runtime/instruction-formats
- https://source.android.com/docs/core/runtime/dalvik-bytecode
- https://source.android.com/docs/core/runtime/dex-format

## M1 — Interpreter core

Implemented slice:

- Incoming parameters occupy the final `ins_size` register words, including
  wide values; calls and entry-triggered class initializers use one shared
  instruction budget across the call tree.
- Integer, long, float, double, object, null, array, and host values; instance
  and static fields; object and array allocation.
- Move/constant/return, branches and switches, arrays, fields, invoke and
  invoke-range, conversions, comparisons, arithmetic, literal, and two-address
  opcode families reached by the current fixtures.
- Java-compatible integer divide/remainder edge cases, reference identity,
  exception handlers, recursion limit, cancellation, and trace callback.
- Exact declaring-class/name/prototype dispatch for interpreted and host calls;
  static/instance kind, invoke word count, caller `outs_size`, wide-register
  pairing, logical argument categories, and return categories are checked.
- One-time DEX class initialization, including DEX superclass initialization,
  before static use and allocation; failed initialization remains failed.
- Precise unresolved-class/method/opcode failures instead of treating arbitrary
  VM errors as compatibility success. Trace entries include depth and canonical
  method identity.

Still required before M1 is complete:

- Full instruction and payload coverage for the expanding corpus.
- Dynamic virtual/interface target selection across the receiver hierarchy.
- A pre-execution verifier for register types, targets, code-item layout, and
  exception tables.
- Differential fixtures against AOSP-compatible reference execution.

This work is tracked in [GitHub issue #1](https://github.com/taizaki69/Kami/issues/1).

## M2 — Java/Kotlin and Android-compatible host surface

The current exact-signature allow-list covers only behavior reached by the
synthetic and pinned-corpus tests:

- `java.lang.Object`, `String`, and `StringBuilder` basics.
- Confined Java reflection over DEX fields and the source-base field bag;
  primitive boxes, atomics, concurrent maps, bounded lists, and iterators.
- Kotlin `Intrinsics`, `Result`, basic synchronous continuation setup, lazy
  values, pairs, `isBlank`, regex construction, and mutable reference boxes.
- Mihon filter/filter-list construction and state access, plus construction
  shims for `HttpSource` and `ParsedHttpSource` superclasses.
- The date-pattern object needed by the pinned BatCave constructor.

The measured next layer is the OkHttp request surface, beginning with the exact
`FormBody.Builder` constructor above, followed by transport isolation and
response limits. The longer tail remains string/collection overloads, Kotlin
duration and full coroutine resumption, serialization, Jsoup, preferences, and
Android context/UI shims. A class appearing in the analyzer's
`implementedClasses` set is only a coarse prioritization signal; it does not
mean every method on that class is callable.

## M3 — tachiyomix source bridge

The target is a signature-aware bridge from `HttpSource`, `SManga`, `SChapter`,
`MangasPage`, filters, network helpers, and Jsoup helpers onto `KamiSource`.
Per-source network clients must own rate limits, cookies, and redacted tracing.
The first end-to-end extension is tracked in
[GitHub issue #2](https://github.com/taizaki69/Kami/issues/2).

## M4 — WebView/Cloudflare bridge

Use a `WKWebView` session only for user-solved challenges, then synchronize its
cookies and User-Agent back into the source's native network session. There is
no claim of bypassing challenges.

## Untrusted-input boundary

The current parsers reject malformed table ranges, non-progressing chunks,
overlong LEB128 values, excessive field/entry counts, encrypted or multi-disk
ZIPs, oversized entries, decompression bombs, invalid DEX versions, and failed
ZIP/DEX/zlib/gzip checksums. Interpreter execution has instruction, call-depth,
array-size, host-collection-size, and cancellation limits. Native host calls
require an exact method prototype and static/instance kind.

Checksums establish corruption detection, not publisher identity. APK signer
verification must land before downloaded extensions are enabled for execution;
that gate is tracked in
[GitHub issue #3](https://github.com/taizaki69/Kami/issues/3).

## Verification

`MihonCompatKit` currently has 61 passing tests: 28 interpreter tests, 10 parser
hardening tests (including every truncated prefix of generated DEX and ZIP
fixtures), 8 pinned real-extension executions, and 15 reader/inflate/repository
tests. GitHub Swift CI fetches the SHA-256-locked APK corpus before running them.

The compatibility matrix records the exact versions, hashes, and methods. New
runtime behavior is complete only when it has a focused regression test and,
where applicable, a pinned real-extension assertion.

## Known non-goals or likely incompatibilities

- Extensions that require bundled native `.so` execution.
- Broad Android UI framework behavior beyond a deliberate compatibility shim.
- Downloaded native machine code or JIT compilation on iOS.
- App Store distribution of the downloadable-bytecode runtime without a
  separate policy and review decision; the current target is sideloading.
