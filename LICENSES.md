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
- **Keiyoushi extension test fixtures** — Apache-2.0. Twenty-one exact upstream
  APKs are vendored under `Tests/corpus/` solely as deterministic offline parser,
  signature, execution-fixture, and static-measurement inputs. They are not
  linked into or shipped by the iOS app. Exact hashes/provenance and the
  non-execution/admission boundary are recorded in `Tests/corpus/manifest.json`
  and `Tests/corpus/KEIYOUSHI-EXTENSIONS-NOTICE.md`. The standard Apache-2.0
  license text is reproduced in `Tests/corpus/KEIYOUSHI-LICENSE.txt`. Source:
  <https://github.com/keiyoushi/extensions-source>. Release/catalog repository:
  <https://github.com/keiyoushi/extensions>.

## Runtime dependencies
- **SwiftSoup 2.9.6** — MIT license. Used as the bounded HTML parser and CSS
  selector engine behind the Jsoup compatibility bridge. Source:
  <https://github.com/scinfu/SwiftSoup/tree/2.9.6>.
- **Swift Crypto 3.12.5** — Apache-2.0 license. Used for cross-platform SHA-256
  plus RSA/ECDSA verification before an extension APK is admitted to the
  interpreter.
  Source: <https://github.com/apple/swift-crypto/tree/3.12.5>.
- **AOSP apksig conformance fixtures** — Apache-2.0 license. Six small test
  APKs are vendored at revision `184702d9d18877edf9e5296c4e191cf0aa2b5fbb`
  so signature tests do not depend on a live Gitiles download. Their hashes
  and provenance are locked in `Tests/corpus/manifest.json`, and the upstream
  license is reproduced in `Tests/corpus/AOSP-APKSIG-LICENSE.txt`. Source:
  <https://android.googlesource.com/platform/tools/apksig/>.
- SQLite via the system library.

If a zstd decoder or another runtime dependency is added later, its license
must be recorded here before merge. A dependency's license applies to that
dependency; it does not license Kami's original code.

## Notes
- This project is not affiliated with Mihon, Tachiyomi, or Keiyoushi.
- No copyrighted manga content is bundled; covers/pages are fetched at
  runtime from user-chosen sources.
