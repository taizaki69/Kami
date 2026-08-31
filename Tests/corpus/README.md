# Extension corpus

`manifest.json` is the authoritative lock for three deliberately separate
roles:

- `execution` fixtures are the seven real APKs used by constructor,
  signature, and interpreted-operation tests.
- `measurement` fixtures are the remaining 14 current lib 1.6 release APKs used
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

The fifth exact current-lib executable profile is TuttoAnimeManga 1.6.10
(`eu.kanade.tachiyomi.extension.it.tuttoanimemanga`, version code 10). Its exact
fixture is `tuttoanimemanga.apk`, admitted only for SHA-256
`e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3`, signer
fingerprint
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`, matching
manifest identity, and declared source ID `2102507871480604746`. Deterministic
real-APK regressions cover metadata, popular/latest/search, combined
details/chapters, pages, default image requests, inherited `Referer`/`Origin`
headers, latest sorting with a ten-result cap, and rejection of unsupported
filters/preferences before transport. This uses fake transport and does not
contact a manga site; it proves only this exact APK, not arbitrary PizzaReader-
family compatibility.

On the downloaded-app path, the source factory preflights the exact profile
source-ID set before DEX construction and postvalidates the IDs returned by the
constructed source. Raw exact-profile constructors are intentionally limited to
the built-in/test seam; they still reverify the exact hash and signer, while a
downloaded APK requires persisted admission and the factory.
The host bridge bounds source-model outputs before conversion: manga-page and
page-list collections at 2,048 entries, manga updates at 20,000 chapters, and
each `Page` URL/image URL at 8 KiB.

The app resolves Baozi's per-page `ImageRequest` asynchronously. Supported
interpreted reader requests retain the exact DEX `Request`/tags and configured
client inside the source actor, execute the bounded source-scoped
application/network interceptor chain, and reuse its cookie jar and VM budget.
The supported GET reader path observes redirects and follows sanitized rewritten
locations; the real Baozi fixture proves redirect-domain rewriting to final
image bytes. The app does not yet persist the profile's preference values, and
banner cropping or missing-image behavior remain unproven through reader image
loads. Reader chapter retry uses a structured `.task(id: reloadID)` restart, and
dismissal cleanup invalidates the load generation. Retry-time request
regeneration/expiry is deferred. Reader image fetching inherits the source's
admitted transport policy, defaults to HTTPS-only, validates URL/headers before
transport, and allows HTTP only through explicit source opt-in; redirects remain
governed by the same policy.

All 27 exact APK fixtures are vendored so clean clones and CI remain
deterministic even when upstream rotates release objects. The 21 Keiyoushi APKs
are Apache-2.0 test inputs with attribution in
`KEIYOUSHI-EXTENSIONS-NOTICE.md`; they are not linked into or shipped by the
iOS app. The signer regression covers all seven real Keiyoushi execution APKs:
Akuma, MangaDex, BatCave, Kawii Manga, MangaMelon, Baozi Manhua, and
TuttoAnimeManga.
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
