# Reader

## Implemented

- Persistent left-to-right, right-to-left, and continuous webtoon reading
  modes. Paged mode uses a page-style `TabView`; webtoon mode uses a lazy
  vertical stack and restores the chapter's last-read page.
- A reader settings sheet persists reading mode, black/gray/white background,
  keep-screen-awake, a 0–8 page prefetch window, a 0–32 point webtoon gap,
  per-zone tap actions, page fitting, uniform-border cropping and an optional
  screen-brightness override. Existing preferences retain their defaults.
- Automatic taps use the outer quarter zones for direction-aware previous/
  next navigation and the center half for controls. Each physical zone can
  instead mean previous page, next page, show/hide controls or no action.
  Explicit actions do not reverse in RTL. In webtoon mode Automatic shows
  controls; explicit page actions scroll to the adjacent page and retain the
  existing chapter-boundary navigation. A visible controls button remains
  available when chrome is hidden, including with every tap zone disabled.
- Paged fit modes are whole page, width and height. Oversized pages can be
  dragged at 1×; width starts at the top and height at the reading edge.
  Double-tap zooms around the tapped point to 2.5×; pinch is bounded to 1–5×.
  Pan offsets are clamped to the rendered page. Fitting, cropping, direction
  and viewport changes reset the zoom/pan geometry. Panning an oversized page
  takes precedence over paging swipes; tap actions still turn pages. Webtoon
  keeps its width-based layout and has no zoom/pan recognizers.
- Chapter progress and history persist as the visible page changes. Reaching
  the final page marks the chapter read. Display controls use the same reader
  for online and verified local pages; they do not alter reading-write targets.
- Each page has an independent loading/error state and retry action. Reader
  chrome shows chapter title and exact page progress; a compact progress badge
  remains when chrome is hidden.
- Chapter retry increments a reload identity consumed by a structured
  `.task(id: reloadID)`, so the chapter page list and per-page requests restart
  as one cancellable load. Reader dismissal runs disappearance cleanup, which
  increments the load generation; stale page-list or image-request completions
  are ignored.
- Completed downloads use a source-independent local read lease. Opening a
  saved chapter verifies its manifest and complete file set; each page read
  checks its size and hash before using the shared ImageIO decoder. Local retry
  uses local files, while online reading is an explicit separate action.
  Disabling a source does not close a local reader. Download deletion waits
  for active leases to close and keeps progress/history. See [Downloads](DOWNLOADS.md).

## Display ownership and border cropping

AppModel owns one `ReaderDisplayCoordinator` through the UIKit display bridge.
Only readers in active scenes with an attached window participate. Keep-awake
is the union of their requests; dismissing one window cannot restore the idle
timer while another still needs it. A disabled preference does not cancel
another reader's request. Removing the final requester restores the captured
state without overwriting a distinguishable external change.

Brightness is optional, normalized to 5–100%, and restored after its final
override ends or the scene becomes inactive. The most recently activated or
changed override wins on a shared screen; unrelated renders do not steal
priority. Changes from Control Center/auto-brightness are not repeatedly
overwritten and become the next restoration baseline. If a system change
happens just before closing, it is left intact. A later explicit change or
activation can reapply the stored reader preference.

The bridge resolves the [actual window scene's screen](https://developer.apple.com/documentation/uikit/uiwindowscene/screen).
Apple supports [`UIScreen.brightness`](https://developer.apple.com/documentation/uikit/uiscreen/brightness)
only on the main display, so external-screen brightness is disabled in the
settings UI and filtered again at the bridge. Screen references are released
after the last reader's restoration. Scene/window lifecycle interaction and
physical brightness behavior still require Apple-device validation.

Uniform-border cropping is a reversible display heuristic, disabled by default.
The existing detached ImageIO task also examines an RGBA sample no larger than
512×512 (1 MiB), with cancellation checks. It accepts only matching white,
black or transparent corners and removes fully uniform edge rows/columns,
retaining two sample pixels of padding and at least half of each dimension.
Blank/mixed-corner pages remain whole. Sampling is conservative but not a
semantic artwork detector; turn it off to inspect the full page.

The original bounded thumbnail and its [CGImage subregion](https://developer.apple.com/documentation/coregraphics/cgimage/cropping(to:))
remain available together. Toggling crop switches the rendered image without
re-reading files, refreshing URLs, sending network requests or modifying
downloaded bytes. Both images are released with the existing page lifecycle.
This native reader transform does not implement Android bitmap APIs for APKs.

## Image request and memory boundary

- After page-list resolution, `ReaderView` asynchronously asks the source for
  one exact `ImageRequest` per page. Visible loads and prefetches consume that
  request's URL and headers plus any opaque source-scoped execution capability.
  This replaces `AsyncImage`, which could not honor source-provided Referer,
  User-Agent, authentication headers, or extension client behavior.
- Baozi Manhua 1.6.29 is the current custom-request regression: its real DEX
  `imageRequest(Page)` rewrites the fixture URL from
  `static.baozicdn.com` to `static.baozimh.com` without network I/O, and the
  reader receives the resulting URL/headers projection. With banner processing
  explicitly disabled, it also receives an opaque capability backed by the
  exact actor-owned DEX Request/tags and configured client. One fixture proves
  the redirect-domain tag rewrites a direct 302; a second runs the same real APK
  interceptor against an observable exchange and follows its rewritten
  source-host `Location` to final image bytes.
- `ReaderImagePipeline` is source-scoped and actor-isolated. Production loads
  reuse the compatibility transport's deterministic header validation,
  five-redirect limit, HTTPS-downgrade rejection, streamed 32 MiB response
  limit, and isolated in-memory cookie jar.
- Concurrent requests for the same URL/header identity share one network task.
  Source-scoped execution adds its UUID to that identity, preventing different
  hidden tags/runtime state from colliding at the same public URL.
  Compressed bytes use a 64 MiB LRU cache, and prefetch is capped at eight
  requests. Reset/cancellation cannot let an old request clear or populate a
  newer load generation.
- PNG chunk bounds, ordering, CRCs and the terminal IEND are checked before
  ImageIO, which may otherwise salvage a truncated PNG. Other image formats
  continue through ImageIO's format and decoding checks.
- Image metadata is checked before decode. Inputs with dimensions above 100,000
  pixels on either axis or 250 million source pixels are rejected. ImageIO
  downsamples off the main actor to at most 6,144 pixels in paged mode and
  4,096 pixels in webtoon mode.
- Paged mode retains decoded images only for the current page and its immediate
  neighbors. Webtoon pages release their decoded image when they leave the lazy
  viewport; compressed prefetch bytes remain available within the LRU budget.

Plain native requests use the image pipeline's own source-scoped cookie jar.
An interpreted request with a supported execution capability instead reuses the
extension runtime's configured transport and cookie jar, preserving cookies
established while resolving the page list. The DEX Request/client graph never
leaves the source actor; KamiCore sees only URL/headers, an opaque UUID, and the
bounded response.

Reader image fetching inherits the source's admitted transport policy. It is
HTTPS-only by default, validates each initial URL and its headers before even an
injected transport sees them, and accepts `http://` only when that source was
explicitly configured for insecure HTTP. Redirect handling uses the same
source-scoped policy, while reader-specific response-size limits stay separate.

Supported reader image capabilities execute the same bounded source OkHttp
surfaces as source operations, preserving exact DEX Request identity/tags and
one VM instruction budget. For the supported GET-only reader path, application
interceptors wrap the complete call once while network interceptors see each
single exchange. Rewritten redirect locations are resolved and followed under
the source's five-hop, downgrade, secret-stripping, response-size, cancellation,
32-interceptor, 64-step, and depth-32 bounds. Baozi's optional banner transform
still requires unavailable Android Bitmap/pixel/JPEG behavior, so the
downloaded-source factory explicitly defaults `BAOZI_BANNER=0`; explicit modes
1/2 keep the safe URL/header path. General source-operation and non-GET OkHttp
follow-up semantics remain outside this measured reader seam.

Explicit per-page Retry asks the source for a fresh `ImageRequest` and replaces
that page's URL/header snapshot without merging old headers or changing chapter
progress/history. A nil result fails without falling back to the old request.
Generation and cancellation checks prevent late source resolutions from
publishing into another chapter load. Ordinary page reactivation reuses the
latest snapshot; a retry interrupted before its image fetch completes keeps its
cache bypass pending.

The pipeline validates each public request before cache or in-flight reuse.
Retry removes the exact identity's compressed cache entry, including a 200 body
that later failed ImageIO decoding, and replaces any ordinary prefetch for that
identity. Concurrent retries share an active reload. UUID guards prevent a
superseded flight from clearing or populating the new flight's cache entry, and
canceling the initiating caller does not discard a shared result. Source-owned
execution UUIDs remain part of request identity. Requests have no generic TTL;
explicit Retry is the refresh trigger and does not imply automatic login,
OAuth, challenge, or credential renewal.

All six reader regressions pass locally on Windows. At exact checkpoint
`fd15d76`, [Swift CI](https://github.com/taizaki69/Kami/actions/runs/35416577528)
passes them on macOS and proves ImageIO rejects the invalid cached body and decodes the replacement
PNG. [iOS Build](https://github.com/taizaki69/Kami/actions/runs/35416577530)
passes simulator and unsigned-device compilation, and
[IPA Package](https://github.com/taizaki69/Kami/actions/runs/35416577529)
uploads the unsigned app. Physical-device interaction and performance remain
unverified.

## Tracked next

1. Previous/next chapter navigation, end-of-chapter behavior, and configurable
   tap-zone actions.
2. Dual-page spreads on iPad and landscape, including cover-page separation.
3. Fit-width/fit-height controls, crop-borders, brightness override, and
   tap-centered zoom with stricter pan bounds.
4. Memory-pressure-driven cache purging and long-image tiling. Persistent
   chapter downloads now have a separate bounded store and local read leases.
5. Add Baozi image-transform regressions only after a portable bounded
   pixel/JPEG codec exists; a metadata-only Bitmap shim is not compatibility.
6. Physical-device profiling and accessibility testing, including 500-page
   webtoon chapters, rotation, VoiceOver labels, and interrupted/retried loads.
