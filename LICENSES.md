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
None. SQLite via the system library; no third-party SPM packages. If a zstd
decoder or HTML parser is vendored later, their licenses must be recorded
here before merge (candidates under review: Apache-2.0 or MIT options only).

## Notes
- This project is not affiliated with Mihon, Tachiyomi, or Keiyoushi.
- No copyrighted manga content is bundled; covers/pages are fetched at
  runtime from user-chosen sources.
