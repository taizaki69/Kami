# Saved FoolSlide website

FoolSlide Customizable 1.6.6 uses one source ID for configurable websites.
Relative manga and chapter URLs from two installations must not be combined
under that ID. Kami retains the content's website independently of executable
settings, APK installation and enablement.

This contract is only for the measured package
`eu.kanade.tachiyomi.extension.all.foolslidecustomizable`, source ID
`6351052922295965587`. It adds no execution profile or support for multiple
websites simultaneously under that ID.

## Durable state and migration

Schema 7 adds `source_content_binding`: the source ID, `deployment` or
`unresolved`, an optional HTTPS URL and a positive local Int64 revision.
The URL is limited to 4 KiB and follows the measured product schema.
It contains no trust, enablement, adult flag, APK identity, cookie or file path.
There is no installation foreign key. The schema-6 reading epoch is unchanged.

The migration runs inside its schema transaction. It reads prior installation
and preference data after bounding column types/lengths and validating UTF-8.
Matching measured identity, fingerprint, schema revision and complete typed
settings may establish the exact website. This is descriptive evidence:
migration never reads or executes APK bytes, so disablement or a missing APK
does not invalidate it. Existing manga without valid provenance receive an
unresolved binding. With neither proven configuration nor manga, the row stays
absent. Legacy unbound preferences and the loopback placeholder prove no website.
A database failure rolls back the schema, seed and version together.

After migration, export reads the durable binding without inferring a replacement
from current settings. Known provenance survives re-admission, preference
deletion/corruption and uninstall. Missing or malformed binding data fails
faithfully. Native backup source descriptions accompany archived manga;
settings for an otherwise empty source remain outside library export.
The local binding revision is never exported as an authority or token.

SQL invariants require a binding before Foo manga insertion or source
reassignment. Any stored Foo manga, including nonlibrary and hidden-chapter
parents, prevents changing its kind or URL. Binding rows cannot be deleted or
reinserted to reset revisions, including through `INSERT OR REPLACE`.
Explicit changes in an empty namespace use a checked revision increment.

## Settings and execution

Settings snapshots read binding, installation and preference state together.
Save reauthenticates the APK and checks all captured state in one write
transaction. URL identity and snapshot equality use exact UTF-8 bytes,
including host case, percent spelling and Unicode composition. No normalization
or inferred URL equivalence relabels stored content.

| Saved state | Manga present | Explicit authenticated Save |
| --- | --- | --- |
| No binding | No | Establish the chosen valid website |
| Known A | Yes | Accept only exact A, even without a previous preference document |
| Known A | No | Keep A or deliberately change it with a new binding revision |
| Unresolved | Yes | Reject assignment; the requested URL cannot prove the original website |
| Unresolved | No | Establish a valid website with a new revision |
| Missing binding with manga, or malformed binding | Either | Reject without silently repairing |

Adult-only changes preserve the binding revision. Preference revision and
existing download invalidation still advance atomically. Rejected saves leave
preferences, binding, downloads and content unchanged. A late preference-write
error also rolls back a new or replaced binding. Saving never implicitly
enables an extension or grants APK trust.

The settings form shows the saved website as reference, or states that the
original website is unknown. Opening that reference does not populate
executable settings.

Factory configuration loading requires a known binding matching the saved URL.
Final execution/source-result/update/download checks include the binding and
its revision. Detail, the online reader and `LibraryService.refresh` also check
captured configuration before source requests. A nil Foo configuration cannot
bypass this check. Offline leases and reading progress remain independent of
executable configuration.

## Verification and remaining work

The [dated record](VERIFICATION-2026-10-04-CONTENT-BINDING.md) describes actual
test and compilation scope. Tests cover migration, retained descriptions without
APK files, first configuration of existing content, re-admission, URL-byte
distinctions, stale/exhausted revisions, malformed data, transactional rollback
and rejection before injected provider calls.

Restore remains unavailable. This binding supplies identity and conflict
prerequisites, not an immutable preview, atomic library merge, general operation
barriers, transport draining or invalidation across all scenes. Source results
and category/membership writes still need the broader restore epoch/intent
contract. No physical-device interaction, performance or live-site result
follows from these deterministic tests.
