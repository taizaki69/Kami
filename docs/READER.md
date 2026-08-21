# Reader

## Implemented (v0.1)
- Paged mode via `TabView(.page)`: LTR (default), vertical paging (same pager,
  rotated content), RTL pending the direction setting (tracked below).
- Page fetch honoring per-source `getImageRequest` (Referer/User-Agent when a
  source requires them).
- Progress persistence: page index → `chapter.last_page_read`; history rows
  recorded on page change.
- Tap zones/double-tap zoom, black background, per-page failure states with
  retry placeholder.

## Tracked next (priority order)
1. RTL reading direction + reader settings sheet (background, tap zones).
2. Continuous vertical (webtoon) mode: `LazyVStack` in a `ScrollView` with
   prefetch window and memory-bounded image decoding (downsample via
   `CGImageSourceCreateThumbnailAtIndex`; verified crucial for 500+ page
   chapters).
3. Prefetch: next N pages ahead, aggressive cancellation behind.
4. Dual-page spread mode on iPad/landscape.
5. Keep-screen-awake (`UIApplication.isIdleTimerDisabled`), brightness
   override, crop-borders option.

## Performance notes
- Images decode off the main thread; pages leaving the prefetch window are
  dropped from the in-memory cache (NSCache with totalCostLimit scaled to
  memory-pressure notifications).
- The mission's profiling pass (very large chapters) happens against the
  webtoon implementation, not the pager.
