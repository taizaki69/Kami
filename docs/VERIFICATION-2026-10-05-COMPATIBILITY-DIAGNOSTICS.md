# Compatibility diagnostics verification — 2026-10-05

Implementation base: `bc6f03e798728b7813f931f83c7d455764a02262` (PR #27).
The implementation PR records the final head, identical CI merge tree,
workflow runs and artifact evidence after publication. This file does not
preclaim a future Apple run or physical Files-provider interaction.

## New regressions

Seven `InterpretedCompatibilityExportTests` cover conservative type/member/
prototype syntax, path-shaped and malformed symbols, forged-report sanitation,
strict promotion rejection, deterministic ordering and deduplication, canonical
round-trip, count/byte limits with whole-line truncation, omission counters,
saturating arithmetic, empty reports, invalid bounds/counts and cancellation.

Five `SourceCompatibilityDiagnosticsTests` cover immutable report snapshots,
exact registration identity, native/absent capability, revocation before and
during capture, cancellation drainage and library-operation exclusion. A real
hash/signature-pinned BatCave 1.6.9 fixture fails at an injected typed transport
gap, is registered through the pinned-source API, exports its captured report
without another transport call, and produces the expected `promote-gap` seed.
No live manga site or arbitrary APK was invoked.

The existing diagnostic regressions continue to cover caught host fallbacks,
external-field behavior, arbitrary-error exclusion and static corpus tooling.
The export additions do not grant new source compatibility or trust.

## Verification limits

Local Swift 6.3.3 checks pass: 179 portable Core, 421 Core/SQLite and 379
MihonCompatKit tests. App/hosted-test source parse, Markdown references and
whitespace checks are part of local review.

App source parsing and local package suites are distinct from Apple builds.
The implementation PR reports complete local/remote test counts and artifacts
for the exact published head. Existing hosted UIKit tests exercise reader
rendering, not this diagnostic screen. Files-provider cancellation, navigation,
accessibility and multiple-scene interaction remain separate validation tasks.

The 4 MiB cap bounds exported bytes, not all transient recorder/sort/FileWrapper
allocations or process memory. Broader app, storage and download diagnostics
remain open; a typed compatibility report does not explain every source failure.
