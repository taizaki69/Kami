# Reader controls verification — 2026-10-04

Branch: `assistant/reader-controls-20261004`.
Base: `2251ffc6034471434dca867e1eced6cbf889d38e` from
[PR #23](https://github.com/taizaki69/Kami/pull/23), ready and unmerged. That
base passed all five checks with a matching CI/head tree: 372 Compat on each
host, 368 SQLite Core on Linux and 371 Core on macOS, iOS simulator/device
compilation and unsigned IPA packaging.

This increment integrates the [reader controls](READER.md) into the existing
online/offline reader: persistent per-zone tap actions, whole-page/width/height
fitting, bounded pan/zoom, reversible border cropping and a brightness override.
Shared ownership replaces each reader's independent idle-timer restoration.

## Local and platform verification

Linux Swift 6.3.3 through `scripts/linux-dev` passed **390 Core/SQLite**, **148
portable Core** and **372 MihonCompatKit** tests, all with zero failures. App
frontend parsing and whitespace checks pass separately from Apple compilation.
Exact-head Apple CI results and artifact identities are recorded on the
implementation PR and under `.git/checkpoints/20261004-reader-controls/`.

Twenty-two new portable Core tests exercise:

- Old preference decoding/defaults, new fields' round trip and finite bounds.
- Automatic LTR/RTL/webtoon taps, exact physical zone boundaries, explicit
  actions and rejection of nonfinite/out-of-range positions.
- Fit geometry, initial reading-edge/top alignment, clamped base/zoomed pan,
  zoom-anchor preservation and invalid dimensions/scales.
- Prefetch arithmetic at the integer limit.
- White/black/transparent crop bounds, retained padding/content, blank pages,
  mixed corners, edge marks, raster budgets and cancellation.
- Overlapping keep-awake owners, preexisting/external state, brightness
  priorities, unrelated renders, closing in either order, screen movement,
  reactivation, disabled overrides, quantized outputs and unavailable screens.
- System brightness changes suppress older overrides until an explicit
  preference change or activation; closing a reader cannot revive one.

Two additional ImageIO cases run only on Apple hosts. They exercise real PNG
decode and crop output, original-image/source-byte preservation, asymmetric
pixel coordinates and blank-page dimensions. The existing cancellation case
also requests crop preparation. Their outcome must come from the exact-head
Apple workflow, not Linux's conditionally compiled tests.

## Scope of the evidence

The Core coordinator is driven by synchronous injected display reads/writes.
Those tests prove its ownership/restoration policy. The production UIKit bridge
resolves the actual window screen and releases on inactivity/window removal;
Apple CI checks its compilation. Neither proves physical UIKit scene event
ordering, recognizer interactions, Control Center behavior or hardware output.

Apple documents brightness support only on the main screen. External-screen
brightness is disabled and filtered; multi-screen policy tests do not claim
unsupported hardware control. The native crop is a bounded display heuristic
and does not add Android bitmap compatibility or modify downloaded files.

Physical Files/multiwindow checks, accessibility interaction, long-image
tiling, memory-pressure purging and large-library/device performance remain
open. No live manga sites, arbitrary APK execution, personal image/backup files,
credentials, licensing or system services were used or changed. The broad
daily-reader and compatibility goal remains active.
