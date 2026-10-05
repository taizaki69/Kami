# Reader memory-warning verification — 2026-10-05

This increment is based on `c180f57661e2834bdf7450709bd5ebe0eff5711e`,
[PR #24](https://github.com/taizaki69/Kami/pull/24), on
`assistant/reader-memory-20261005`. It addresses the reader-memory task in
TODO.md; long-image tiling and measured device performance remain separate work.

## Behavior under test

- UIKit's memory warning reaches the actual online/offline reader store. The
  reader retains a constrained policy until it closes, including chapter
  resets: no compressed cache refill or speculative prefetch after the warning.
- The pipeline tracks individual demanded/speculative waiters. A prefetch that
  gained a live demanded caller continues; cancellation releases that ownership
  and stops the flight once no demanded caller needs it under pressure. Flight
  UUIDs protect later requests from old completions and cancellation handlers.
- Paged residency contracts from current ±1 to current. Webtoon residency uses
  viewport intersections plus neighbors normally, and visible pages under
  pressure. A programmatic target remains eligible before geometry arrives.
  Scalar original/cropped ratios survive pixel eviction and later reactivation.
- Existing visible bitmaps are resized off-main to at most 2,048 pixels per
  axis. The already selected crop, source metadata and logical layout are
  preserved. This path needs no compressed bytes or source/file/network call.
  Cancellation and image revisions prevent replacing a newer page or Retry.
  New image decodes use the reduced bound after the warning.

## Local evidence

Linux Swift 6.3.3 passes:

- 156 portable KamiCore tests.
- 398 KamiCore tests with the explicit SQLite module/linker flags.
- 372 MihonCompatKit tests, including the locked corpus and source execution
  regressions. No arbitrary APK or live manga website was used.
- SwiftUI source syntax parsing and `git diff --check`.

Eight added portable cases cover 500-index residency, boundaries and pending
jumps, no cache refill across reset, retained source header/HTTPS policy,
prefetch-to-visible sharing, ownership cancellation before/after pressure, and
late canceled transport completion while a new visible flight is pending.
The existing reload/shared-caller/revocation regressions remain in the suites.

Three additional Apple-only cases exercise real CoreGraphics bitmap reduction:
asymmetric pixels and crop origin, exact bounded dimensions/source metadata,
blank-crop sharing, no upscaling, normalized limits and canceled reduction.
Linux cannot run these or type-check the UIKit integration.

## Publication evidence

The implementation PR records the immutable published head and tree, workflow
run/job URLs, Linux/macOS test totals, simulator/device compilation, and unsigned
IPA metadata after those jobs finish. Pending remote jobs are not local proof.
The CI merge commit must have the same tree as the published head. Logs,
publication manifests and final readback are retained in
`.git/checkpoints/20261005-reader-memory/`.

## Remaining validation

On an Apple simulator/device, open online and downloaded chapters in paged and
webtoon modes. Trigger a memory warning while prefetch is pending and while a
page is zoomed/cropped; check that the current image stays readable, no extra
fetch occurs for its reduction, offscreen images release, and scroll height,
zoom/pan and saved progress remain stable. Repeat through Retry, chapter
navigation, rotation, multiple reader windows and dismissal. Confirm a reopened
reader regains the normal policy. Profile 500-page chapters and very long images
with Instruments, including transient replacement allocations.

These are interaction/performance checks, not claims from package assertions or
successful compilation. Warning delivery is best-effort; this change does not
guarantee a process-wide memory ceiling or immunity to termination. Long-image
tiling, signed-device installation and accessibility interaction remain open.
