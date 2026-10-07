# Source migration verification — 2026-10-05

Implementation base: `fb93560fdc468447b8c43423f489f95c5eafb016` (PR #29).
The implementation PR records its final head, identical CI merge tree,
workflow jobs and artifacts after publication. This document does not claim a
future Apple run or physical migration interaction.

## New regressions

Seven portable `SourceMigrationTests` cover unique fractional/zero matches,
duplicate and unknown numbers, explicit unmatched coverage, byte-distinct
Unicode URLs, repeated URL rejection, finite-number and 20,000-chapter bounds,
malformed/empty provider catalogs, exact search/detail identity continuity,
projection that accepts no provider reading-state claims, excluded sources,
and direct selection/registration revocation. Deliberately noncooperative
providers observe cancellation while retaining the coordinator lease until
their response drains, then cannot start the chapter request or publish.

Twelve SQLite `SourceMigrationPersistenceTests` exercise read-only preview;
additive merge preserving original and existing destination state/history;
unchanged download identity records; no page-offset/history copy; optional
categories and deselected matches; repeat-merge behavior; foreign preview and
injected match rejection; external ABA expiration; revoked candidate rejection;
same-manga and missing-membership rejection; mandatory destination execution
configuration; Unicode byte identities; origin identity replacement during
preparation; retained FoolSlide deployment with configuration CAS; partial-write
rollback; active durable update/download exclusion; queued cancellation; and
successful epoch/presentation publication despite cancellation after COMMIT.

Fixtures never execute arbitrary APKs or visit manga sites. The configuration
regression uses descriptive pinned identity records and an in-memory provider;
its APK path does not exist. Download-record preservation tests compare exact
stored job bytes; they do not claim to migrate or render downloaded files.

## Verification limits

All 19 new regressions pass in the full local Swift 6.3.3 suites: 202 portable
Core, 456 Core/SQLite and 379 Compat tests. App and hosted-test source parsing
and whitespace checks also pass.

App source parsing is distinct from SwiftUI typechecking. The implementation
PR supplies exact-head Linux/macOS suites, simulator/device builds and unsigned
IPA evidence. Existing hosted simulator tests exercise reader rendering, not
the migration screens. Device touch, VoiceOver, multiwindow behavior and large
library performance remain open. Manual chapter pairing, replacing/removing
the original, source pagination and the broader reader/compatibility objective
are not completed by this additive flow.
