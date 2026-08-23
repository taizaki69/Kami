# Licenses and Attribution

## Kami original code
Apache License 2.0 (see repository license file when added). Original work:
all Swift sources in this repository.

## Interoperability references (read, not copied)
- **Mihon** (Apache-2.0) and **tachiyomix** (MPL-2.0 for spec, Apache-2.0 for
  library) — studied to reproduce extension manifest keys, index formats, and
  API semantics. No source code copied.
- **Keiyoushi extensions** — third-party content fetched at runtime by user
  action for analysis/testing; never bundled.

## Runtime dependencies
- **SwiftSoup 2.9.6** — MIT license. Used as the bounded HTML parser and CSS
  selector engine behind the Jsoup compatibility bridge. Source:
  <https://github.com/scinfu/SwiftSoup/tree/2.9.6>.
- SQLite via the system library.

If a zstd decoder or another runtime dependency is added later, its license
must be recorded here before merge (Apache-2.0 or MIT options only).

## Notes
- This project is not affiliated with Mihon, Tachiyomi, or Keiyoushi.
- No copyrighted manga content is bundled; covers/pages are fetched at
  runtime from user-chosen sources.
