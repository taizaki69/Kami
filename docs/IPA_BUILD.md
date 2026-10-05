# Building the IPA

Reviewed **2026-10-04** against `main` at `a479806`. An unsigned IPA is a
packaged device app; simulator compilation and a signed installation are
separate steps. No physical-device installation is established by CI.

## GitHub Actions

The [IPA Package workflow](../.github/workflows/ipa.yml) builds Release for
`generic/platform=iOS` with signing disabled, packages `Payload/Kami.app`, and
uploads `Kami-unsigned-ipa`. Select the run for the intended PR head, check
that the packaging/upload job passed, and download that run's artifact.
See [project status](PROJECT_STATUS.md) for the verified continuation artifact.

## Equivalent local unsigned build

On macOS with Xcode and XcodeGen, from the repository root:

```bash
bash scripts/bootstrap.sh
xcodebuild -project Kami.xcodeproj -scheme Kami \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath derived CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Package the produced app without relying on the older helper:

```bash
(
  set -euo pipefail
  test -d derived/Build/Products/Release-iphoneos/Kami.app
  mkdir -p dist
  ipa_output="$(pwd)/dist/Kami-unsigned.ipa"
  ipa_stage="$(mktemp -d)"
  trap 'rm -rf "$ipa_stage"' EXIT
  mkdir "$ipa_stage/Payload"
  cp -R derived/Build/Products/Release-iphoneos/Kami.app "$ipa_stage/Payload/"
  rm -f "$ipa_output"
  cd "$ipa_stage"
  zip -qry "$ipa_output" Payload
)
```

`scripts/package_ipa.sh` in the reviewed main has unsigned-suffix and relative
output-path failures, plus an obsolete `PackageApplication` path. Its repair
is tracked in [TODO.md](../TODO.md); the independent CI workflow does not call
that helper. `scripts/build.sh simulator` produces a simulator `.app`, not a
device IPA.

## Signing and device validation

Use your own signing identity and provisioning through Xcode or a signing
workflow you control. The app bundle ID is `app.kami.reader`. Signing does not
prove a successful installation or reader interaction; record those checks
separately. Keep certificates, profiles, passwords and account secrets out of
the repository.
