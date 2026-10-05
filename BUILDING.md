# Building Kami

Reviewed **2026-10-04** against `main` at `a479806`. Commands below refer to
files in that snapshot. See [project status](docs/PROJECT_STATUS.md) for the
open continuation PRs and their separate verification evidence.

## Package tests on macOS, Linux or Windows

The SwiftPM manifests use tools version 5.9. Dependencies are pinned in the
manifests; use a toolchain compatible with them. The continuation is tested
with Swift 6.3.3 on Linux. Windows also needs its C++ build tools and SDK.

Run from the repository root:

```bash
bash scripts/fetch_corpus.sh
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
swift build --package-path Packages/MihonCompatKit -c release --product compat-audit
```

On Windows, the existing command-prompt helper can run either package:

```bat
scripts\windows_dev_test.bat Packages\MihonCompatKit test
scripts\windows_dev_test.bat Packages\KamiCore test
```

KamiCore conditionally compiles SQLite and ImageIO code. A passing portable
suite without those modules does not validate database migrations or image
decoding. The reviewed `main` package links SQLite on Apple platforms; the
Linux SQLite harness and `scripts/linux-dev` helper belong to the continuation
starting at [PR #10](https://github.com/taizaki69/Kami/pull/10).

`scripts/test.sh` currently runs KamiCore only when `xcodebuild` is available.
It also attempts an app test action when a generated project exists, although
`project.yml` defines no app test target. Use the explicit package commands
above for package verification and the build commands below for app compilation.
Correcting this helper is tracked in [TODO.md](TODO.md).

## iOS app on macOS

The app targets iOS 17.0 on iPhone and iPad; the packages declare iOS 16.0 and
macOS 13.0 minimums. Use Xcode with a compatible Swift compiler and iOS SDK,
and install XcodeGen before generating the project:

```bash
brew install xcodegen
bash scripts/bootstrap.sh
xcodebuild -project Kami.xcodeproj -scheme Kami \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Kami.xcodeproj -scheme Kami \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

`project.yml` is the source of truth; do not commit generated per-machine
project files. A simulator build, an unsigned device build and an installed
signed app are different validation steps. Physical-device interaction and
performance remain unverified. See [IPA builds](docs/IPA_BUILD.md).

## Deterministic extension corpus

The [manifest](Tests/corpus/manifest.json) locks 27 artifacts: 10 labelled
`execution`, 11 labelled `measurement`, and 6 AOSP conformance fixtures.
Nineteen are current lib 1.6 releases. These labels lag the catalog:
EternalMangas and DocTruyen3Q have exact runtime profiles/tests while their
files remain under `measurement/` on `main`.

`fetch_corpus.sh` verifies SHA-256 before accepting a fixture and uses the
recorded upstream URL only as a recovery attempt. Corpus membership does not
grant signer trust or permission to execute an APK. Tests use fake transport.
See the [corpus guide](Tests/corpus/README.md) for provenance and role details.

To reproduce the non-executing static audit:

```bash
swift run --package-path Packages/MihonCompatKit compat-audit gaps Tests/corpus/measurement
```

The checked-in [baseline](Tests/corpus/measurement-baseline.json) records
11 analyzed artifacts, 7 structural candidates, 4 wrapper blockers,
**387** unique unregistered external method surfaces, no omitted invocations
and no unsupported opcodes. These counts prioritize investigation; they do
not measure runtime compatibility.

## GitHub Actions and evidence

The reviewed `main` has three workflows, all on `macos-15`:

| Workflow | What it verifies |
| --- | --- |
| [Swift CI](.github/workflows/ci.yml) | Corpus hashes, both Swift package suites, optimized `compat-audit` build and artifact |
| [iOS Build](.github/workflows/ios-build.yml) | Generic simulator and unsigned generic-device compilation |
| [IPA Package](.github/workflows/ipa.yml) | Release device build, ZIP packaging and unsigned IPA artifact |

Record the PR head, CI checkout/merge commit, tree, job results and artifact
identity when reporting verification. A green run for an older commit does
not validate a new change. Platform-specific test counts differ because of
conditional modules.

The old 262 compatibility / 30 macOS core / 19 portable core counts describe
the `fd15d76` reader-retry checkpoint, not current verification. Historical
run links remain in [HANDOFF.md](HANDOFF.md). The latest verified continuation
head, counts and runs are recorded in [project status](docs/PROJECT_STATUS.md).
