# Reviewed source migration

Open a saved manga and choose **Migrate to another source** in its toolbar.
Submit a destination search, choose a result and review the proposed chapter
matches. The original source can be unavailable: its saved data supplies the
reading state. Destination sources must be enabled, authenticated and ready.

Search uses the shared **Sources and languages** selection and the
[global-search bounds](GLOBAL_SEARCH.md): up to 64 selected registrations,
three provider searches at once and 20 first-page results per source. Refine
the title to find another destination. Search and preview do not save manga.

## Review and transfer

- A suggestion requires a finite, nonnegative chapter number occurring once
  in both the original's stored chapters and the fetched destination list.
  Fractional numbers and zero are retained. Titles and scanlators are shown
  for review; matching numbers alone do not establish identical content.
- Deselect any unsuitable match. A separate list explains every unmatched
  original chapter: unknown number, duplicate number or no destination number.
  Coverage also counts destination chapters without suggestions. Hidden original
  chapters participate, so previously saved editions can make a number ambiguous.
- Confirm that you checked the destination and selected matches, then apply.
  The destination enters the library and missing fetched chapters are added.
  Selected matches copy read and bookmark flags by union; existing flags stay set.
  Category copying is optional and preserves existing destination assignments.
- The original remains in the library. Its metadata, membership, chapters,
  downloads, history and page positions stay intact. History and downloaded
  pages are not attributed to another provider. New destination chapters start
  at page index zero, even if the original has a saved page position.
- Existing destination metadata, chapter identities/currentness, history and
  page offsets are preserved. Chapters absent from the fetched list are kept.
  Missing discovery baseline entries are added without generating update alerts.

A migration with zero selected pairs still adds the destination; the preview
states the zero coverage before confirmation. A subsequent normal source
refresh uses the ordinary chapter-currentness and discovery rules.

## Ownership and atomicity

The route captures the original's store-issued reading snapshot. Before
previewing, Core validates its store/epoch and the original row's exact source
ID and UTF-8 manga URL. It never obtains a fresh epoch for an old route's row ID.
Destination detail must retain the exact search-result URL bytes. Duplicate
chapter URL bytes, empty chapter catalogs, malformed and oversized data fail
preparation. Chapter URLs use byte identity, including Unicode spellings that
Swift string comparison would consider equal.

The candidate retains both source registration and discovery-selection
lifetimes. Revocation cancels provider work; the library lease remains owned
until the provider drains. A selection change is not evidence that an active
provider has already stopped. Commit makes no provider requests.

The store issues an immutable preview with a bounded full-domain fingerprint,
connection/external-change stamp, epoch and captured destination execution
configuration. The stamp catches changes that return to the same value (ABA).
Commit accepts only a subset of that preview's match IDs. It rejects another
store's preview, stale state, revoked candidates, pending durable updates or
active download publication. FoolSlide's authenticated configuration and saved
deployment namespace are revalidated inside the write transaction; migration
never changes or infers that namespace.

The shared app coordinator reserves exclusion before scheduling commit and
refuses open readers or pending operations. SQLite rolls back additions,
flag/category changes and epoch rotation on failure or early cancellation.
A successful commit rotates the data epoch and app presentation generation,
invalidating old readers/routes. Cancellation after COMMIT reports success
and still publishes the new generation.

## Limits and remaining work

Destination validation uses the bounded library model: 20,000 chapters per
manga, 4 KiB identity URLs, 8 KiB metadata fields, 256 KiB descriptions and
32 MiB aggregate retained strings, with the existing library-wide row bounds.
The combined stored state is validated before COMMIT. These are retained-data
bounds, not a measurement of provider allocations or peak device memory.

This first flow is additive. Manual arbitrary pairing for ambiguous/unknown
numbers, replacement/removal of the original and destination pagination remain
open. No history, progress-page or download transfer across providers is
claimed. Physical-device, VoiceOver, multiwindow and large-library interaction
need separate validation. See [verification](VERIFICATION-2026-10-05-SOURCE-MIGRATION.md).
