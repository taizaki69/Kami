#!/usr/bin/env bash
# Build the Kami app for iOS Simulator (macOS + Xcode required).
# Usage: scripts/build.sh [device|simulator] [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="${1:-simulator}"
CONFIG="${2:-debug}"

if [ ! -f Kami.xcodeproj/project.pbxproj ]; then
  command -v xcodegen >/dev/null || { echo "error: xcodegen required (brew install xcodegen)"; exit 1; }
  xcodegen generate
fi

case "$DESTINATION" in
  simulator) FLAG="-destination 'generic/platform=iOS Simulator'" ;;
  device) FLAG="-destination 'generic/platform=iOS'" ;;
  *) echo "unknown destination $DESTINATION"; exit 1 ;;
esac

eval xcodebuild -project Kami.xcodeproj -scheme Kami -configuration "$CONFIG" "$FLAG" build
