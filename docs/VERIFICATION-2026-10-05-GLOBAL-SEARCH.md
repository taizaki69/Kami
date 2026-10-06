# Global search verification — 2026-10-05

Implementation base: `230f1de51687234ab0042cb96bcfdd11c887f208` (PR #26).
The implementation PR records the final head, matching CI tree, workflow runs
and artifact evidence after publication. This file does not preclaim a future
Apple build or physical-device result.

## Deterministic regressions

Eleven `GlobalSearchSessionTests` exercise the production coordinator with
injected source operations and revocable registration snapshots:

- Three-provider concurrency, queued-source admission, early partial results,
  registry ordering and failure isolation. Calls use page one, trimmed query
  and empty filters; feeds and dynamic-filter refresh are forbidden by fixtures.
- Late, deliberately noncooperative cancellation followed by query replacement;
  obsolete results cannot appear and replacement calls wait for drainage.
- Rapid replacement skips the intermediate query and retains the final result.
- Explicit cancellation and cancellation of the awaiting parent suppress late
  results. Queued sources never start after cancellation.
- A real `LibraryOperationCoordinator` keeps restore excluded until cancelled
  provider work drains, then admits the exclusive operation.
- Synchronous cancellation from a progress observer clears the presentation
  without starting a provider or indexing its removed groups.
- Revoked registrations fail before invocation and before publication; healthy
  sibling results remain available.
- Empty/oversized queries, duplicate source IDs and too many sources fail before
  provider work. Oversized/malformed pages and retained-byte limits fail only
  the affected source.
- Exact UTF-8 path identity, cross-source separation, duplicate suppression,
  explicit 20-item preview/pagination limits and discarded full-detail metadata.

Local Swift 6.3.3 portable KamiCore: 174 tests pass; SQLite-enabled KamiCore:
416 tests pass. MihonCompatKit: 372 tests pass. Apple workflows and unsigned IPA
are recorded separately on the PR for the published commit. Existing hosted UIKit renderer
tests concern the reader; they do not establish global-search UI interaction.

## Review boundaries

The actual Browse screen exposes the feature. AppModel uses ready registry
snapshots; the screen runs inside the shared library-operation coordinator,
clears stale presentations, and guards navigation by revision and registration
UUID. The per-source destination carries the submitted query into the existing
search/pagination flow. Full search UI navigation, keyboard behavior, interrupted
network conditions and multiple scenes still require Apple interaction checks.

No live manga sites or arbitrary APKs were used to establish this behavior.
No source profile, admission rule, database schema or stored library was changed.
Global search is not a migration engine and does not resolve the broader TODOs.
