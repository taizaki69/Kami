#!/usr/bin/env bash
# Package an installable .ipa.
#
# Default: unsigned simulator-style archive repackaged (sideload tools sign on
# install). With DEVELOPMENT_TEAM set: signs a device build with the given
# team; Xcode manages the signing identity/profiles.
#
# Usage: scripts/package_ipa.sh [DEVELOPMENT_TEAM_ID]
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="${1:-${DEVELOPMENT_TEAM:-}}"
CONFIG="Release"
OUT="dist"
mkdir -p "$OUT"

if [ ! -f Kami.xcodeproj/project.pbxproj ]; then
  command -v xcodegen >/dev/null || { echo "error: xcodegen required"; exit 1; }
  xcodegen generate
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SIGNING_ARGS=()
if [ -n "$TEAM" ]; then
  SIGNING_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM")
else
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

echo "==> Building archive"
xcodebuild -project Kami.xcodeproj -scheme Kami -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  "${SIGNING_ARGS[@]}" \
  build

APP="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/Kami.app"
[ -d "$APP" ] || { echo "error: $APP not produced"; exit 1; }

echo "==> Packaging IPA"
IPA="$OUT/Kami$( [ -n "$TEAM" ] && echo "-signed" ).ipa"
rm -rf "$BUILD_DIR/Payload" "$IPA"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
if [ -n "$TEAM" ]; then
  /usr/bin/xcrun -sdk iphoneos PackageApplication "$BUILD_DIR/Payload/Kami.app" -o "$(pwd)/$IPA" || {
    echo "falling back to zip packaging"
    (cd "$BUILD_DIR" && zip -qry "$(pwd)/$IPA" Payload)
  }
else
  (cd "$BUILD_DIR" && zip -qry "$(pwd)/$IPA" Payload)
fi

echo "==> Done: $IPA"
echo "Install via: AltStore / Sideloadly / TrollStore / idevicesinstaller (signing happens at install time for unsigned builds)."
