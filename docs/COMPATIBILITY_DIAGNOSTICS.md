# Compatibility diagnostics

Extensions → Compatibility diagnostics lists ready, enabled source instances
that expose the runtime reporting capability. Choose a source to inspect its
package/version, recorded gaps, stages and occurrence counts. Select a gap to
read/copy its full exported symbol, or choose Save report to Files to keep the
reviewed snapshot as plain text. Refresh captures newly recorded gaps.

The screen does not execute source operations to manufacture a report, enable
an extension, change trust or send data automatically. It does not post issues.
The native MangaDex source does not produce interpreter compatibility reports.
Disabled/replaced sources and construction failures without a published instance
do not have a report in this screen. Runtime reports are in memory for their
source instance; restarting or replacing it clears that instance's recording.
Files already saved by the user are independent snapshots.

## What a report means

The existing recorder retains stage-deduplicated typed unresolved class,
method/prototype, field and opcode surfaces, including the first typed gap below
host fallbacks. Arbitrary error descriptions, HTTP/parser failures, cancellation
and budget errors are not recorded. No findings means no accepted gap has been
recorded in this instance; it is not proof of complete compatibility or successful
network access. This screen is not a general application or network log.

Package/version and typed runtime symbols are the only variable report inputs.
The exporter does not read requests, responses, URLs, cookies, credentials,
source configuration, file paths, manga titles, reading history or library data.
Identity strings are sanitized again at export. Runtime symbols use a
conservative ASCII subset of the [DEX string grammar](https://source.android.com/docs/core/runtime/dex-format#string-syntax):
complete type descriptors, member names and method names plus prototypes.
Array depth is capped at 255. Unsafe or unsupported diagnostic spellings become
`<redacted-symbol>`; literal slash-delimited paths cannot pass simply because
their characters occur in the DEX alphabet. Unicode symbols remain redacted.
This output policy does not change bytecode admission or runtime semantics.

## Deterministic export and bounds

`InterpretedCompatibilityExport.prepare` revalidates counts and metadata,
deduplicates sanitized stage/surface pairs and sorts them by stage, kind and
symbol. It exports a prefix of at most 512 findings and 4 MiB, with no partial
lines. The recorder itself admits at most 4,096 unique findings and caps each
symbol at 4 KiB. Export counts saturate at `Int.max` rather than overflowing.

The screen separately reports export-omitted unique findings and occurrences,
and occurrences that the recorder could not retain. The canonical `dropped:`
footer combines the latter two occurrence counts. Sanitization can coalesce
different unsupported spellings into the same redacted surface. The displayed
snapshot is exactly the bounded report saved to Files; no larger hidden payload
is attached. Export filenames do not contain queries, paths or source settings.

The output retains the canonical `Kami compatibility report v1` format accepted
by `compat-audit promote-gap`. A nonempty exported report can seed a deterministic
regression for its first sorted gap; an empty report has no gap to promote.
Truncation/loss counters make missing coverage explicit.

## Lifetime and interaction

`SourceCompatibilityDiagnostics.prepare` requires a revocable registry snapshot.
It reads and formats off-main, checking cancellation and registration availability
before and after capture. The caller waits for its detached worker to drain.
AppModel also verifies readiness and the same registration UUID before publishing.
The shared library-operation coordinator keeps restore excluded during capture.

The UI admits one preparation per report screen and retains its busy state until
a cancelled worker drains. Leaving the screen cancels preparation; replacing or
disabling the source removes its prepared presentation. Save captures immutable
bytes only while that registration is current. Once the user opens Files, that
selected snapshot is independent of later source changes. Cancellation of the
Files picker is normal; other save failures show a generic message without
provider error text or paths.

Deterministic package and locked-APK tests cover capture, loss accounting,
redaction and promotion. Apple compilation and existing renderer tests are
separate from diagnostics navigation or Files-provider interaction; see the
[verification record](VERIFICATION-2026-10-05-COMPATIBILITY-DIAGNOSTICS.md).
