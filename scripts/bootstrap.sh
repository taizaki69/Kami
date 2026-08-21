#!/usr/bin/env bash
# Kami bootstrap: install tooling and fetch an extension test corpus.
# Requires macOS with Xcode for app work; the pure-Swift packages also build
# on Linux/Windows with a Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking tools"
command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version | head -1 || echo "xcodebuild not found (iOS builds need Xcode)"
command -v xcodegen >/dev/null 2>&1 && xcodegen --version || {
  echo "xcodegen not found. Install with: brew install xcodegen"
}

echo "==> Generating Xcode project (if xcodegen available)"
command -v xcodegen >/dev/null 2>&1 && xcodegen generate || true

echo "==> Fetching extension test corpus (optional; network required)"
./scripts/fetch_corpus.sh || echo "(corpus fetch skipped)"

echo "Bootstrap complete."
