#!/usr/bin/env bash
# Run all tests.
# - macOS/Linux/Windows host: SwiftPM tests for the pure-Swift packages
#   (MihonCompatKit fully; KamiCore DB tests need SQLite3, i.e. macOS/Linux).
# - macOS: additionally runs the iOS app tests via xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> MihonCompatKit (swift test)"
swift test --package-path Packages/MihonCompatKit

if command -v xcodebuild >/dev/null 2>&1; then
  echo "==> KamiCore (swift test, macOS)"
  swift test --package-path Packages/KamiCore
  if [ -f Kami.xcodeproj/project.pbxproj ]; then
    echo "==> Kami app (xcodebuild test)"
    xcodebuild -project Kami.xcodeproj -scheme Kami -destination 'platform=iOS Simulator,name=iPhone 16' test
  fi
fi
echo "All available tests passed."
