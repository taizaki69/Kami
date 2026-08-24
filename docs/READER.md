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

## Image request and memory boundary

- Visible loads and prefetches consume the source's exact `ImageRequest` URL
  and headers. This replaces `AsyncImage`, which could not honor source-provided
  Referer, User-Agent, or authentication headers.
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

## Tracked next

1. Previous/next chapter navigation, end-of-chapter behavior, and configurable
   tap-zone actions.
2. Dual-page spreads on iPad and landscape, including cover-page separation.
3. Fit-width/fit-height controls, crop-borders, brightness override, and
   tap-centered zoom with stricter pan bounds.
4. Memory-pressure-driven cache purging, long-image tiling, and integration
   with the future persistent download/disk cache.
5. Share source cookies safely between interpreted requests and reader images;
   add a real extension fixture proving a custom image request and continuity.
6. Physical-device profiling and accessibility testing, including 500-page
   webtoon chapters, rotation, VoiceOver labels, and interrupted/retried loads.
