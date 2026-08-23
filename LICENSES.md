# Licenses and Attribution

## Kami original code

Copyright (c) 2026 [taizaki69](https://github.com/taizaki69). All rights
reserved.

Kami is currently published **without a project license** while its creator
decides between proprietary, source-available, commercial, and open-source
distribution. No permission is granted to use, copy, modify, redistribute,
sublicense, or sell Kami's original code beyond rights supplied directly by
GitHub's Terms of Service for material in a public repository.

Public visibility is not an open-source license. Do not add or infer an
Apache-2.0, MIT, GPL, or other project license without the creator's explicit
decision.

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
- **Swift Crypto 3.12.5** — Apache-2.0 license. Used for cross-platform SHA-256
  verification before a pinned extension APK is admitted to the interpreter.
  Source: <https://github.com/apple/swift-crypto/tree/3.12.5>.
- SQLite via the system library.

If a zstd decoder or another runtime dependency is added later, its license
must be recorded here before merge. A dependency's license applies to that
dependency; it does not license Kami's original code.

## Notes
- This project is not affiliated with Mihon, Tachiyomi, or Keiyoushi.
- No copyrighted manga content is bundled; covers/pages are fetched at
  runtime from user-chosen sources.
