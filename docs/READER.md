# Reader

## Implemented

- Persistent left-to-right, right-to-left, and continuous webtoon reading
  modes. Paged mode uses a page-style `TabView`; webtoon mode uses a lazy
  vertical stack and restores the chapter's last-read page.
- A reader settings sheet persists reading mode, black/gray/white background,
  keep-screen-awake, a 0–8 page prefetch window, and a 0–32 point webtoon gap.
- Paged controls use the outer quarter tap zones for direction-aware previous/
  next navigation and the center half for chrome. Double-tap toggles 2.5x zoom;
  pinch zooms from 1x to 5x and a zoomed page can be panned. Webtoon taps toggle
  chrome without installing zoom gestures that compete with scrolling.
- Chapter progress and history persist as the visible page changes. Reaching
  the final page marks the chapter read. The previous system idle-timer state
  is restored when the reader closes.
- Each page has an independent loading/error state and retry action. Reader
  chrome shows chapter title and exact page progress; a compact progress badge
  remains when chrome is hidden.
- Chapter retry increments a reload identity consumed by a structured
  `.task(id: reloadID)`, so the chapter page list and per-page requests restart
  as one cancellable load. Reader dismissal runs disappearance cleanup, which
  increments the load generation; stale page-list or image-request completions
  are ignored.

## Image request and memory boundary

- After page-list resolution, `ReaderView` asynchronously asks the source for
  one exact `ImageRequest` per page. Visible loads and prefetches consume that
  request's URL and headers. This replaces `AsyncImage`, which could not honor
  source-provided Referer, User-Agent, or authentication headers.
- Baozi Manhua 1.6.29 is the current custom-request regression: its real DEX
  `imageRequest(Page)` rewrites the fixture URL from
  `static.baozicdn.com` to `static.baozimh.com` without network I/O, and the
  reader receives the resulting URL/headers projection.
- `ReaderImagePipeline` is source-scoped and actor-isolated. Production loads
  reuse the compatibility transport's deterministic header validation,
  five-redirect limit, HTTPS-downgrade rejection, streamed 32 MiB response
  limit, and isolated in-memory cookie jar.
- Concurrent requests for the same URL/header identity share one network task.
  Compressed bytes use a 64 MiB LRU cache, and prefetch is capped at eight
  requests. Reset/cancellation cannot let an old request clear or populate a
  newer load generation.
- Image metadata is checked before decode. Inputs with dimensions above 100,000
  pixels on either axis or 250 million source pixels are rejected. ImageIO
  downsamples off the main actor to at most 6,144 pixels in paged mode and
  4,096 pixels in webtoon mode.
- Paged mode retains decoded images only for the current page and its immediate
  neighbors. Webtoon pages release their decoded image when they leave the lazy
  viewport; compressed prefetch bytes remain available within the LRU budget.

The image pipeline has its own source-scoped cookie jar. It does **not yet**
inherit cookies established by the extension runtime while resolving the page
list. Extensions that need that continuity remain a measured compatibility gap,
even though explicit image-request headers are now honored correctly.

Reader image fetching inherits the source's admitted transport policy. It is
HTTPS-only by default, validates each initial URL and its headers before even an
injected transport sees them, and accepts `http://` only when that source was
explicitly configured for insecure HTTP. Redirect handling uses the same
source-scoped policy, while reader-specific response-size limits stay separate.

The reader image seam currently receives only URL/headers. It does not retain
DEX `Request` identity or tags, and the await path does not execute source
OkHttp interceptors. Baozi banner cropping, redirect-domain rewriting, and
missing-image handling are therefore not executed or proven through reader
image loads; URLSession's own redirect handling does not establish those
interceptor semantics.

Per-page image retry currently restarts the image task with the same resolved
`ImageRequest`; it does not regenerate the request from the source or define
expiry/credential-refresh behavior. Retry-time request regeneration and expiry
semantics are explicitly deferred.

## Tracked next

1. Previous/next chapter navigation, end-of-chapter behavior, and configurable
   tap-zone actions.
2. Dual-page spreads on iPad and landscape, including cover-page separation.
3. Fit-width/fit-height controls, crop-borders, brightness override, and
   tap-centered zoom with stricter pan bounds.
4. Memory-pressure-driven cache purging, long-image tiling, and integration
   with the future persistent download/disk cache.
5. Share source cookies safely between interpreted requests and reader images;
   then run a bounded source interceptor/tag chain through the reader seam.
   Add image-transform regressions only after the chain preserves request
   identity and response semantics.
6. Physical-device profiling and accessibility testing, including 500-page
   webtoon chapters, rotation, VoiceOver labels, and interrupted/retried loads.
