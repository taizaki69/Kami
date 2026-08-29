# Extension corpus

`manifest.json` is the authoritative lock for three deliberately separate
roles:

- `execution` fixtures are the five real APKs used by existing constructor,
  signature, and interpreted-operation tests.
- `measurement` fixtures are current lib 1.6 release APKs used only for bounded
  parsing, structural planning, and static compatibility-gap ranking.
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

All 27 exact APK fixtures are vendored so clean clones and CI remain
deterministic even when upstream rotates release objects. The 21 Keiyoushi APKs
are Apache-2.0 test inputs with attribution in
`KEIYOUSHI-EXTENSIONS-NOTICE.md`; they are not linked into or shipped by the
iOS app. Verify every pinned byte sequence with:

```sh
bash scripts/fetch_corpus.sh
```

The script accepts an already-vendored file only when its SHA-256 matches the
lock. If a fixture is missing or hash-mismatched, it attempts the recorded
upstream URL as a convenience fallback; `git restore Tests/corpus` is the
durable recovery path when an upstream release has rotated away. Swift tests
verify the complete lock/fetch mapping, APK manifest identities,
signature-parser acceptance for measurement releases, and the deterministic
static baseline in `measurement-baseline.json`.
