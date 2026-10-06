# Global search

Browse → Search all sources accepts a title and searches the ready, enabled
source registrations when the user submits. The query is sent to those sources
using their default filters. Typing alone does not send requests. Results stay
grouped in registry order, labelled by source and language; completed groups are
usable while other sources are still searching. An empty group and a failed
source are shown separately.

Each group previews up to 20 distinct matches from the first source page.
“More results” or “Search in…” opens that source with the submitted query, where
the existing pagination, retry, refresh and filter controls apply. It starts a
fresh source search; global previews are not a combined exhaustive catalog.

## Ownership and source changes

`GlobalSearchSession` consumes immutable `SourceRegistrationSnapshot` values.
AppModel captures only published, ready registrations whose execution
configuration is available. Search does not install, enable or construct sources,
refresh dynamic filters, visit feeds, or persist manga/results/query history.

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

Source selection, language filters, cross-source ranking and migration/chapter
matching are separate tasks. Live-source availability and physical-device search
interaction are not established by deterministic fixtures or compilation.
See the [verification record](VERIFICATION-2026-10-05-GLOBAL-SEARCH.md).
