# Reader tiled-rendering verification — 2026-10-05

Base: `c5ae522f57732e6316ee8eb1804784cbecb769a0`,
[PR #25](https://github.com/taizaki69/Kami/pull/25).
Branch: `assistant/reader-tiles-20261005`.

## Product change

The previous 4,096-pixel longest-axis cap reduced a 512×12,000 webtoon image to
roughly 175 pixels wide. The reader now budgets long images by area: 16,777,216
pixels normally and 4,194,304 under pressure, with a 65,536-pixel longest axis.
The native fixture checks preservation of the full 512-pixel width normally and
more than 400 pixels under pressure. Ordinary pages retain their previous
resolution limits. Source limits, strict PNG checks, download validation,
transport, retry identity and persisted reading state retain their boundaries.

Both reading layouts draw through a CATiledLayer child of a UIKit view.
Clipped tiles use immutable snapshots and integral source regions with
interpolation overlap. Pressure/replacement creates a fresh tile surface while
the parent retains logical sizing and zoom/pan. Tile drawing still references a
bounded whole decoded bitmap; it is not region decoding and does not establish
constant process memory regardless of source size.

## Verification

Local Swift 6.3.3 passes 163 portable Core, 405 Core/SQLite and 372 Compat
tests, with zero failures. The implementation PR records these results, followed
by exact-head Linux/macOS CI, simulator/device compilation and unsigned IPA.
Seven new portable cases cover resolution budgets, rounding/orientation,
invalid dimensions, tile interpolation overlap, partial edges and invalid clips.
The local app syntax parse cannot replace Apple type checking or rendering.

Four Apple-only Core tests exercise native ImageIO decode/reduction, real pixel
equivalence across adjacent tiles, clipping and orientation, plus invalid and
canceled input. Download validation remains on its small thumbnail path.

The simulator workflow now has a hosted `KamiTests` target and runs two UIKit
rendering cases, using generated local fixtures only. It compares the live
window output against UIImageView after asynchronous tile drawing, replacement,
tall-page displacement and resizing. A blank screenshot cannot pass: the
reference must contain the expected white edge and multiple distinct colors.
Failure screenshots are retained in the xcresult artifact. This adds runtime
rendering evidence beyond the previous compile-only simulator job; consult the
PR for its actual outcome, not a presumed pass from this source document.

The PR records the published head/tree, matching CI merge tree, immutable run
and job URLs, test counts and artifact digests after completion. Logs and
readback live in `.git/checkpoints/20261005-reader-tiles/`.

## Still unproven

Region decoding or a bounded tile-file pipeline, worst-case decoder/cache
memory, 500-page performance, SwiftUI gesture interactions at every zoom/fit,
system memory-warning delivery, multiwindow lifecycle, VoiceOver and physical
device behavior remain open. Pixel budgets do not include every temporary or
format-dependent allocation. A successful simulator fixture is scoped runtime
evidence, not validation of every reader interaction or unrestricted sources.
