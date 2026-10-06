# Source selection verification — 2026-10-05

Implementation base: `c85f2a4a25b261c2652a7d5b26f5661f2f6ace0b` (PR #28).
The implementation PR records its final head, identical CI merge tree,
workflow runs and artifacts after publication. This document does not claim a
future Apple run or physical editor interaction.

## New regressions

Eleven `SourceDiscoveryPreferencesTests` cover all/none and the source/language
intersection; case-normalized but distinct regional/multi-language tags;
canonical signed Int64 JSON and retained unavailable choices; malformed,
duplicate/escaped-key, missing-field, version, depth, byte and count rejection;
the largest supported selection; actual atomic file save/reopen; stale and
ABA editor revisions; unchanged-save behavior; corrupt/unreadable data;
changed/deleted saved bytes; failures before/after write and mismatched
readback; and explicit recovery without overwriting bad data on load. File
tests exercise first launch with both existing and absent parent directories.
An additional classification regression accepts explicit Cocoa/POSIX absence
codes while rejecting permission, corruption, unknown-wrapper and foreign-domain
errors. Foundation distinguishes its general and read-specific
[missing-file error codes](https://developer.apple.com/documentation/foundation/nsfilereadnosuchfileerror-c.enum.case);
the adapter handles both and POSIX `ENOENT` without broadening other failures.

Five new `GlobalSearchSessionTests` verify that 90 registered fixtures are
filtered before the 64-source limit and only the two selected language/source
matches receive the query; none/revoked selections never call providers;
revocation from a progress observer prevents provider start; and a selection
change after a partial result clears old previews, prevents the fourth queued
provider from starting and retains library-operation exclusion until the
three deliberately noncooperative active providers have drained.
Another test observes cancellation delivered directly to an active provider
when the store changes, without a UI observer, and verifies that its late
response cannot publish or release library ownership before drainage.

These 16 additions and the existing 11 global-search regressions pass in the
full local Swift 6.3.3 suites: 195 portable Core, 437 Core/SQLite and 379 Compat
tests. App/hosted-test source parsing, 61 relative Markdown references and
whitespace checks pass. Source parsing remains separate from SwiftUI
typechecking; the implementation PR records exact-head Apple results.

## Verification limits

Package tests exercise the same selection store, canonical file adapter and
search service used by the app, with deterministic provider behavior. They do
not prove touch interaction, VoiceOver, multi-window presentation, file-system
power-loss durability, live extension availability or process-memory bounds.
The existing hosted simulator tests exercise reader rendering, not the new
selection editor. The full reader/compatibility goal, source migration and
broader source identity adapters remain open.
