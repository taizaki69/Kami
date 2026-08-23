#!/usr/bin/env bash
# Fetches the pinned real-extension corpus used by execution tests. APKs stay
# ignored by Git; immutable URLs plus SHA-256 checks keep CI reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS="Tests/corpus"
mkdir -p "$CORPUS"

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "No SHA-256 utility found (expected shasum or sha256sum)" >&2
    return 1
  fi
}

download() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local destination="$CORPUS/$name.apk"
  local temporary="$destination.tmp.$$"

  if [[ -f "$destination" ]] && [[ "$(sha256 "$destination")" == "$expected" ]]; then
    echo "==> $name.apk already matches the corpus lock"
    return
  fi

  trap 'if [[ -n "${temporary:-}" ]]; then rm -f "$temporary"; fi' EXIT
  echo "==> Fetching $name.apk"
  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --tlsv1.2 "$url" --output "$temporary"
  [[ "$(sha256 "$temporary")" == "$expected" ]]
  mv "$temporary" "$destination"
  trap - EXIT
}

download \
  akuma \
  "https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-all.akuma-v1.4.10.apk" \
  "9f5e744ee3066ccf0c785dc8f427af8b7854933997eee1fe349fea388d4ba39a"

download \
  mangadex \
  "https://github.com/keiyoushi/extensions/releases/download/01cba61/tachiyomi-all.mangadex-v1.4.212.apk" \
  "543dcf6a89e5843528a147b658d0b8dc51baa12135682a5ad33c53fc1b306fa3"

download \
  batcave \
  "https://github.com/keiyoushi/extensions/releases/download/a18924b/tachiyomi-en.batcave-v1.6.9.apk" \
  "f5338a90f9b9b40c27a2106ceb1e0c94713c38208998fd735bfabda18934fab6"

echo "==> Pinned corpus ready"

# Audit each APK when a release compat-audit binary is already present.
BIN="Packages/MihonCompatKit/.build/release/compat-audit"
if [[ -x "$BIN" ]]; then
  for apk in "$CORPUS"/*.apk; do
    echo "==> Auditing $(basename "$apk")"
    "$BIN" inspect "$apk" | sed -n '1,12p'
  done
fi
