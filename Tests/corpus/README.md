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

Real extension APKs remain ignored by Git. Restore every pinned byte sequence
with:

```sh
bash scripts/fetch_corpus.sh
```

The fetcher restores each recorded URL and checks the result against the
SHA-256 in the lock; the hash, not release-tag mutability, pins the exact bytes.
Swift tests then verify the complete lock/fetch mapping, APK manifest
identities, signature-parser acceptance for measurement releases, and the
deterministic static baseline in `measurement-baseline.json`.
