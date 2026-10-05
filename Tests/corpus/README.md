# Extension corpus

Reviewed **2026-10-04** against `main` at `a479806`. The
[manifest](manifest.json) is the authoritative byte/URL lock. The executable
catalog and runtime tests are separate evidence; see the
[compatibility matrix](../../docs/EXTENSION_COMPATIBILITY_MATRIX.md).

## Manifest roles and catalog membership

The lock contains 27 APKs with these labels:

| Role | Count | Intended purpose |
| --- | ---: | --- |
| `execution` | 10 | Two legacy lib 1.4 constructor fixtures and eight current lib 1.6 source profiles |
| `measurement` | 11 | Current lib 1.6 parser, structural-plan and static-gap fixtures |
| `conformance` | 6 | AOSP apksig cases, including deliberately unsigned/invalid inputs |

Nineteen locked artifacts are current lib 1.6. The labels are stale for two
files: `measurement/eternalmangas.apk` and `measurement/doctruyen3q.apk`
already have exact executable profiles and deterministic source-operation
suites. Main therefore has **ten exact current profiles**, not eight. Their
presence in the measurement directory must not be described as absence of
runtime coverage, nor should a role label authorize execution.

[PR #10](https://github.com/taizaki69/Kami/pull/10) reconciles those roles and
adds the exact FoolSlide profile: that continuation has 13 execution fixtures
(two legacy plus eleven current), 8 measurement fixtures and 6 conformance
fixtures. It is unmerged; do not apply its counts to main.

The current main profiles are BatCave, Kawii Manga, MangaMelon, Baozi Manhua,
TuttoAnimeManga, Mangas-Origines.fr, Komikcast/VoraToon, Yomu Comics/SSSCanlator,
EternalMangas and DocTruyen3Q. Versions, hash identities, tested operations and
limits are recorded in the matrix. The legacy Akuma and MangaDex fixtures
have constructor coverage, not full source-operation coverage.

## Static measurement

The set is selected by behavior family and shape, not statistically sampled.
The main [baseline](measurement-baseline.json) analyzes all eleven files with
zero errors, seven structural candidates, four stable-wrapper blockers,
**387** unique unregistered external method surfaces, zero omitted invocations
and zero unsupported opcodes. The four blockers are Komga, MangaPlus,
NHentai.xxx and XCOMIC. The seven candidates include the two already catalogued
profiles noted above.

Run from the repository root:

```bash
swift run --package-path Packages/MihonCompatKit compat-audit gaps Tests/corpus/measurement
```

The audit never executes DEX. Static invocations can resolve through another
receiver or be unreachable; their count is not a runtime failure count or
compatibility percentage. Corpus membership does not grant signer trust,
install or enable an APK, or authorize site access. Signature-parser acceptance
alone is not the persisted repository-key/user trust decision required by the
app. Real-APK runtime tests inject deterministic transport.

## Fixture integrity and provenance

All 27 fixtures are vendored so clean clones and CI do not depend on release
rotation. The 21 Keiyoushi APKs are Apache-2.0 test inputs with attribution in
[KEIYOUSHI-EXTENSIONS-NOTICE.md](KEIYOUSHI-EXTENSIONS-NOTICE.md); they are not
linked into or shipped by the iOS app. The AOSP conformance fixtures retain
their pinned upstream provenance and notice.

```bash
bash scripts/fetch_corpus.sh
```

The script accepts an existing fixture only when its SHA-256 matches the lock.
A missing/mismatched file triggers a best-effort fetch of the recorded URL,
which must produce the same bytes. Prefer recovery from the committed fixture
when an upstream object is no longer available; preserve intentional local
changes before restoring files.

`CorpusLockTests` validates the lock/fetch mapping, manifest and signature
parser behavior, and deterministic static baseline. Exact profile tests
separately verify hash/signer/manifest/source-ID admission and measured
operations. Keep these boundaries distinct when adding or promoting a fixture.
