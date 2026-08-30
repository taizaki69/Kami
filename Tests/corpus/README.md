# Extension corpus

`manifest.json` is the authoritative lock for three deliberately separate
roles:

- `execution` fixtures are the six real APKs used by constructor,
  signature, and interpreted-operation tests.
- `measurement` fixtures are the remaining 15 current lib 1.6 release APKs used
  only for bounded parsing, structural planning, and static compatibility-gap
  ranking.
- `conformance` fixtures are small AOSP apksig inputs, including intentionally
  invalid and unsigned APKs.

The measurement set is behavior-stratified, not statistically sampled. It
covers dominant generated families, custom/API-heavy sources, preferences,
custom image requests, and source-factory shapes from 3 through 108 sources.
Its presence does **not** grant signer trust, admit an extension, install it,
execute DEX, contact a manga site, or prove compatibility. The tests do verify
the release signatures as parser conformance, but exact trust and admission
remain in Kami's separate repository-key and install-admission policy, and
executable profiles remain an explicit fail-closed catalog.

The fourth exact current-lib executable profile is Baozi Manhua 1.6.29
(`eu.kanade.tachiyomi.extension.zh.baozimanhua`, version code 29). Its exact
fixture is `baozimanhua.apk`, admitted only for SHA-256
`7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec`, signer
fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, matching
manifest identity, and declared source ID `5724751873601868259`. The runtime
regression covers deterministic popular/latest/search/details/chapters/pages,
one header plus four static `Select` filters, bounded scalar preferences, and
the DEX image-request URL rewrite. It also applies a valid non-default tag
selection and observes a distinct filtered request, while mutated filter schemas
fail closed before transport. It uses fake transport and does not contact a
manga site.

On the downloaded-app path, the source factory preflights the exact profile
source-ID set before DEX construction and postvalidates the IDs returned by the
constructed source. Raw exact-profile constructors are intentionally limited to
the built-in/test seam; they still reverify the exact hash and signer, while a
downloaded APK requires persisted admission and the factory.
The host bridge bounds source-model outputs before conversion: manga-page and
page-list collections at 2,048 entries, manga updates at 20,000 chapters, and
each `Page` URL/image URL at 8 KiB.

The app resolves Baozi's per-page `ImageRequest` asynchronously and forwards
its URL/headers to the reader image pipeline. It does not yet persist the
profile's preference values, execute the APK's OkHttp interceptors, retain DEX
`Request` tags, or prove banner cropping, redirect-domain rewriting, or
missing-image behavior through reader image loads. Reader chapter retry uses a
structured `.task(id: reloadID)` restart, and dismissal cleanup invalidates the
load generation. Retry-time request regeneration/expiry is deferred. Reader
image fetching now inherits the source's admitted transport policy, defaults to
HTTPS-only, validates URL/headers before transport, and allows HTTP only through
explicit source opt-in; redirects remain governed by the same policy.

All 27 exact APK fixtures are vendored so clean clones and CI remain
deterministic even when upstream rotates release objects. The 21 Keiyoushi APKs
are Apache-2.0 test inputs with attribution in
`KEIYOUSHI-EXTENSIONS-NOTICE.md`; they are not linked into or shipped by the
iOS app. The signer regression covers all six real Keiyoushi execution APKs:
Akuma, MangaDex, BatCave, Kawii Manga, MangaMelon, and Baozi Manhua.
Verify every pinned byte sequence with:

```sh
bash scripts/fetch_corpus.sh
```

The script accepts an already-vendored file only when its SHA-256 matches the
lock. If a fixture is missing or hash-mismatched, it attempts the recorded
upstream URL as a best-effort fallback; `git restore Tests/corpus` is the
durable recovery path when an upstream release has rotated away. Swift tests
verify the complete lock/fetch mapping, APK manifest identities,
signature-parser acceptance for measurement releases, and the deterministic
static baseline in `measurement-baseline.json`.
