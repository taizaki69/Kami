# Extension Runtime — Measured Status and Staged Plan

**Last updated:** 2026-08-22

## Where we are

Kami has crossed from DEX analysis into controlled execution. The initial M1
interpreter runs synthetic conformance fixtures and shallow methods from three
pinned, current Mihon extension APKs. It is not yet a complete verifier, Java or
Kotlin runtime, network bridge, or end-to-end source implementation.

Measured real-APK behavior today:

- Akuma 1.4.10 and MangaDex 1.4.212 entry constructors return real DEX objects.
- BatCave 1.6.9 returns its real base URL, language, name, and 64-bit source ID.
- No test claims search, details, chapters, pages, filters, HTTP, HTML parsing,
  JSON serialization, coroutines, preferences, or Cloudflare behavior yet.

## Architecture

```text
Extension APK                       (untrusted)
   ↓ bounded ZIP/DEFLATE + CRC      working
AndroidManifest.xml (AXML)          working
classes*.dex                        validated structural parse
   ↓ DexInterpreter                 partial M1; real shallow methods execute
   ↓ Java/Kotlin HostBridge         minimal M2 surface
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
  wide values; calls use one shared instruction budget across the call tree.
- Integer, long, float, double, object, null, array, and host values; instance
  and static fields; object and array allocation.
- Move/constant/return, branches and switches, arrays, fields, invoke and
  invoke-range, conversions, comparisons, arithmetic, literal, and two-address
  opcode families reached by the current fixtures.
- Java-compatible integer divide/remainder edge cases, reference identity,
  exception handlers, recursion limit, cancellation, and trace callback.
- Precise unresolved-class/method/opcode failures instead of treating arbitrary
  VM errors as compatibility success.

Still required before M1 is complete:

- Full instruction and payload coverage for the expanding corpus.
- Prototype-aware overload dispatch in both interpreted and host calls.
- A pre-execution verifier for register types, targets, code-item layout, and
  exception tables.
- Differential fixtures against AOSP-compatible reference execution.

This work is tracked in [GitHub issue #1](https://github.com/taizaki69/Kami/issues/1).

## M2 — Java/Kotlin and Android-compatible host surface

The current explicit allow-list covers only the behavior proven by tests:

- `java.lang.Object`, `String`, and `StringBuilder` basics.
- Kotlin `Intrinsics` null checks and related exceptions.
- Empty construction shims for `HttpSource` and `ParsedHttpSource` superclasses.

The measured next layers are collections and strings, Kotlin duration/regex,
serialization, OkHttp, Jsoup, preferences, Android context/UI shims, and
coroutine continuation state machines. A class appearing in the analyzer's
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
array-size, and cancellation limits.

Checksums establish corruption detection, not publisher identity. APK signer
verification must land before downloaded extensions are enabled for execution;
that gate is tracked in
[GitHub issue #3](https://github.com/taizaki69/Kami/issues/3).

## Verification

`MihonCompatKit` currently has 54 passing tests: 23 interpreter tests, 10 parser
hardening tests (including every truncated prefix of generated DEX and ZIP
fixtures), 6 pinned real-extension executions, and 15 reader/inflate/repository
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
