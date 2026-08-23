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

# Gitiles exposes immutable blob bytes as base64 when `format=TEXT` is used.
download_gitiles() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local destination="$CORPUS/$name.apk"
  local encoded="$destination.b64.tmp.$$"
  local temporary="$destination.tmp.$$"

  if [[ -f "$destination" ]] && [[ "$(sha256 "$destination")" == "$expected" ]]; then
    echo "==> $name.apk already matches the corpus lock"
    return
  fi

  trap 'rm -f "${encoded:-}" "${temporary:-}"' EXIT
  echo "==> Fetching $name.apk"
  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --tlsv1.2 "$url" --output "$encoded"
  # Reading from stdin is portable across GNU coreutils and macOS/BSD
  # `base64`; their positional input-file syntax is not compatible.
  if ! base64 --decode < "$encoded" > "$temporary" 2>/dev/null; then
    base64 -D < "$encoded" > "$temporary"
  fi
  [[ "$(sha256 "$temporary")" == "$expected" ]]
  mv "$temporary" "$destination"
  rm -f "$encoded"
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

# Small Apache-2.0 Android Open Source Project apksig conformance fixtures,
# pinned to one source revision. They cover schemes absent from the extension
# sample without checking generated binaries into Kami.
AOSP_APKSIG_REV="184702d9d18877edf9e5296c4e191cf0aa2b5fbb"
AOSP_APKSIG_BASE="https://android.googlesource.com/platform/tools/apksig/+/$AOSP_APKSIG_REV/src/test/resources/com/android/apksig"

download_gitiles \
  aosp-v3-original \
  "$AOSP_APKSIG_BASE/golden-aligned-v3-out.apk?format=TEXT" \
  "6e606307a39c826330db293a63c677566265d593bcb9b5c6fa58b34f86102668"

download_gitiles \
  aosp-v3-lineage \
  "$AOSP_APKSIG_BASE/golden-aligned-v3-lineage-out.apk?format=TEXT" \
  "e2f5131444fdefb60614ae48c5cd0092ccddd7eceb75b13a349045c9acad8632"

download_gitiles \
  aosp-v1 \
  "$AOSP_APKSIG_BASE/golden-aligned-v1-out.apk?format=TEXT" \
  "b9513e617253cc5864bccd731adeae270861e690a8dae86c15b1ee2aa3f867f4"

download_gitiles \
  aosp-unsigned \
  "$AOSP_APKSIG_BASE/empty-unsigned.apk?format=TEXT" \
  "8739c76e681f900923b900c9df0ef75cf421d39cabb54650c4b9ad19b6a76d85"

download_gitiles \
  aosp-v2-invalid-signature \
  "$AOSP_APKSIG_BASE/v2-only-with-rsa-pkcs1-sha256-2048-sig-does-not-verify.apk?format=TEXT" \
  "ae2f6bf5ae1cf510cc871f0e81bf8577c986362717e91d3bccb63d642760d02e"

download_gitiles \
  aosp-v3-stripped \
  "$AOSP_APKSIG_BASE/v2v3-signed-v3-block-stripped.apk?format=TEXT" \
  "ba6b48842c845d1593f3f54104ab8457e7fafc930ce67d7e61d62eefdf201f95"

echo "==> Pinned corpus ready"

# Audit each APK when a release compat-audit binary is already present.
BIN="Packages/MihonCompatKit/.build/release/compat-audit"
if [[ -x "$BIN" ]]; then
  for apk in "$CORPUS"/*.apk; do
    echo "==> Auditing $(basename "$apk")"
    "$BIN" inspect "$apk" | sed -n '1,12p'
  done
fi
