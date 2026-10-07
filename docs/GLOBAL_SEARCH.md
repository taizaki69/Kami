# Global search

Browse → Search sources accepts a title and searches the selected, ready
source registrations when the user submits. The query is sent to those sources
using their default filters. Typing alone does not send requests. Results stay
grouped in registry order, labelled by source and language; completed groups are
usable while other sources are still searching. An empty group and a failed
source are shown separately.

Each group previews up to 20 distinct matches from the first source page.
“More results” or “Search in…” opens that source with the submitted query, where
the existing pagination, retry, refresh and filter controls apply. It starts a
fresh source search; global previews are not a combined exhaustive catalog.

## Sources and languages

Browse and Global search expose the same “Sources and languages” editor.
Source and language allowlists intersect. “All enabled sources” and “All
languages” include future additions; an explicit list includes only those
choices. Empty lists deliberately select none. Unchecking a choice while
“All” is active creates an explicit list from the currently available choices.
The editor shows the matching count and warns when it exceeds the global
search limit of 64; individual source browsing remains available above it.

Language tags compare without ASCII case. Regional tags such as `pt` and
`pt-BR` remain separate, and `all` identifies a multi-language source rather
than acting as a wildcard. The editor retains selected IDs and language tags
while their sources are disabled or absent and shows those remembered choices.
It does not invent names or install/enable missing sources. Selection uses the
source ID; an enabled source with the same ID is included on a later submission,
while individual result paths still require the original registration UUID.

Edits stay in a draft until Apply. Cancel or dismiss discards the draft.
The app-wide owner compares the editor's revision before saving; a changed
selection requires Reload current selection, so another scene's edits cannot
be overwritten by an old form. Applying an unchanged selection is a no-op.
Applying a change invalidates the previous selection snapshot synchronously;
its scope delivers cancellation directly to active provider tasks. Views also
clear old previews and cancel their search tasks. No search is submitted
automatically after editing, and requests already sent cannot be recalled.

Preferences affect discovery only. Library, History, Updates, Downloads and
compatibility diagnostics still use their own admitted source registrations.
Opening a source from the library remains possible even when it is excluded
from Browse/global search. This is not an extension trust or network permission.

## Persistence and recovery

`SourceDiscoveryStore` is shared by the app's scenes. A small atomic file,
`Application Support/Kami/source-selection.json`, persists independently of
library data and is excluded from native library backups/restores. A missing
file on startup defaults to all sources/languages. Corrupt or unreadable saved
data selects none and shows a review prompt; loading does not overwrite it.
Apply is an explicit recovery action. A changed/deleted file detected before
save invalidates the old editor and selects none until a reviewed retry.
Failed writes or mismatched readback also invalidate active selections instead
of publishing a broader query audience. Atomic replacement and readback do not
claim power-loss durability or an interprocess transaction.

Version 1 JSON requires exactly `version`, `sourceIDs` and `languages`.
Null means all; an empty array means none. IDs use canonical decimal strings
to preserve signed Int64 values. Output sorts IDs/tags deterministically.
The decoder reuses Core's lexical JSON preflight to reject duplicate/escaped
keys, malformed UTF-8/escapes, excess depth and excessive values before Codable.
Limits are 128 KiB input/output, depth 3, 4,096 source IDs and 256 language tags
of at most 64 ASCII bytes. Tags contain nonempty alphanumeric segments separated
by hyphens. The file reader reads at most the input limit plus one sentinel byte.

## Ownership and source changes

`GlobalSearchSession` consumes immutable `SourceRegistrationSnapshot` values.
AppModel captures only published, ready registrations whose execution
configuration is available. Search does not install, enable or construct sources,
refresh dynamic filters, visit feeds, or persist manga/results/query history.
It also consumes a revocable `SourceDiscoverySelectionSnapshot`; source and
language filtering happens before the 64-source bound. Stale selections are
checked at entry, after awaiting an older worker, around enqueue/progress,
before provider invocation and before result publication. A revoked selection
cannot start a queued provider or publish old previews. The app captures this
snapshot before scheduling the library operation and guards navigation with
its revision as well as the source registration. The optional nil selection
in the package API preserves an all-sources seam for existing non-app callers.
The selection scope inherits the request-scope ceiling of 256 simultaneous
operations across scenes; each global-search session still allows only three
concurrent providers. Selection cancellation waits for each provider to drain.

At most three provider calls run concurrently per search session. Each run
owns its task group and awaits completion even when a provider acknowledges
cancellation late. Replacing a query cancels its worker, invalidates its results
immediately, and waits for that worker before starting another fan-out. A newer
replacement skips an intermediate pending query. Cancelling does not release
the library-operation reservation until all provider calls have drained, so
restore cannot overlap unfinished search work. Existing per-source transport,
runtime and admission limits continue to apply.

Each completion checks task cancellation, the query generation and registration
availability. Disabling/reconfiguring a source clears the search presentation.
Result identities use the exact UTF-8 path bytes within each source group;
canonically equivalent strings and identical paths from different sources are
not merged. Detail and per-source search destinations retain the registration
revision and UUID. A replaced registration shows “Source changed” instead of
interpreting its old result path on a newly configured website.

Leaving the screen cancels pending queries while keeping completed previews.
Editing its text clears previews. Retry/search submission always captures a new
set of ready registrations. A noncooperative provider can delay a replacement
and library restore; claiming cancellation alone would not resolve its work.

## Bounds and retained data

- At most 64 sources, three simultaneous calls, and 1,024 input UTF-8 bytes.
- At most 500 items in an individual returned first page; retain at most 20
  unique items. More items or `hasNextPage` makes further results explicit.
- Per item: a nonempty path of at most 8 KiB, title and author at most 4 KiB
  each, and thumbnail URL at most 8 KiB. These are byte bounds, not URL rewrites.
- Retained path/title/author/thumbnail text totals at most 256 KiB per source.
  Description, memo, alternate titles and other full-detail fields are discarded.
  Source responses exceeding the preview contract fail their own group.

These limits bound the search projection, not total process memory or all
provider/cover-image allocations. Errors do not display arbitrary provider
exception strings. The query and results are held only in the open screen.

## Remaining work

Cross-source ranking remains open. The saved-manga
[migration route](SOURCE_MIGRATION.md) now reuses this bounded first-page
search with a separate reviewed, atomic reading-state transfer. Ordinary global
search still performs no library writes.
Live-source availability and physical-device search/editor interaction are not
established by deterministic fixtures or compilation. The selector does not
change a source's content-language filters or broaden Mihon backup adapters.
See the [original search verification](VERIFICATION-2026-10-05-GLOBAL-SEARCH.md)
and [selection verification](VERIFICATION-2026-10-05-SOURCE-SELECTION.md).
