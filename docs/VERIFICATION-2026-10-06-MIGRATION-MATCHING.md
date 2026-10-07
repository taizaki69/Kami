# Manual migration matching verification — 2026-10-06

Implementation base: `558100b519e0f452423259a1cb71a793f929027b` (PR #30).
The implementation PR records its final head, identical CI merge tree, exact
workflow jobs and artifact hashes after publication. This document does not
claim future Apple runs or physical interaction.

## New regressions

Eight portable `SourceMigrationDraftTests` cover numeric defaults, manual
coverage/basis, collision rejection without dropping either pair, explicit
unpair/reassign, invalid/negative/oversized indices, no-op revisions, immutable
selection snapshots, reset and ABA review invalidation, case/diacritic/name/
scanlator/number search without searching URLs, stable indices and complete
pagination/exclusions, empty results, 20,000-chapter/256-byte query/page/metadata
limits, aggregate text bounds and pre-start search cancellation.

Four new SQLite `SourceMigrationPersistenceTests` exercise the real coordinator
with manual unknown/duplicate-number pairs and Unicode-byte-distinct destination
URLs; accurate read/bookmark transfer; unchanged original history/offsets/download
records; zero page offsets and no imported history at the destination; injected
negative/out-of-range indices; duplicate origins/destinations; selection rejection
across otherwise identical previews before exclusive reservation; external ABA
expiration; and cancellation of queued manual work without writes or epoch changes.
The original 19 migration regressions continue covering numeric suggestions,
candidate validation and provider cancellation drainage, configuration/deployment
CAS, source/selection revocation, read-only preview, rollback, existing destination
state and late-cancellation publication through the same commit implementation.

## Verification limits

All 12 new regressions pass in full local Swift 6.3.3 suites: 210 portable
Core, 468 Core/SQLite and 379 Compat tests. App/hosted-test source parsing and
whitespace checks pass; exact-head Apple evidence belongs to the implementation PR.

The app uses bounded local search over the immutable preview and a separate
draft revision for review acknowledgement. Tests prove the Core data/search/
selection/transaction contracts; source parsing and Apple builds do not prove
touch, VoiceOver, keyboard/search presentation or multiwindow navigation. Hosted
simulator tests still exercise reader rendering. Physical interaction, measured
peak memory, replacing/removing the original and destination manga pagination
remain open. Fixtures use no live manga sites or arbitrary APK execution.
