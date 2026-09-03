#!/usr/bin/env bash
# Verifies the vendored execution, static-measurement, and AOSP conformance
# corpus. A recorded upstream URL is only a best-effort recovery fallback for a
# missing or hash-mismatched fixture; the checked-in bytes plus SHA-256 lock
# keep CI independent of upstream release retention.
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS="Tests/corpus"
MEASUREMENT="$CORPUS/measurement"
mkdir -p "$CORPUS" "$MEASUREMENT"

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

  mkdir -p "$(dirname "$destination")"

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

# Real extension bytes are vendored and SHA-256-locked. Recorded release assets
# are only a best-effort fallback for a missing or hash-mismatched local file.
# The measurement subset is used only for bounded parsing, structural planning,
# and static gap ranking. Having it locally does not authenticate, admit, install,
# execute, or contact an extension-declared manga source.
REAL_APKS=()
while IFS='|' read -r name url expected; do
  [[ -n "$name" ]] || continue
  download "$name" "$url" "$expected"
  REAL_APKS+=("$CORPUS/$name.apk")
done <<'LOCKED_REAL_APKS'
akuma|https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-all.akuma-v1.4.10.apk|9f5e744ee3066ccf0c785dc8f427af8b7854933997eee1fe349fea388d4ba39a
mangadex|https://github.com/keiyoushi/extensions/releases/download/01cba61/tachiyomi-all.mangadex-v1.4.212.apk|543dcf6a89e5843528a147b658d0b8dc51baa12135682a5ad33c53fc1b306fa3
batcave|https://github.com/keiyoushi/extensions/releases/download/a18924b/tachiyomi-en.batcave-v1.6.9.apk|f5338a90f9b9b40c27a2106ceb1e0c94713c38208998fd735bfabda18934fab6
kawiimanga|https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-ar.kawiimanga-v1.6.1.apk|9e6110b8d1946180e948d3a890347529a5889e636ca6a001170cd206f74dd52a
mangamelon|https://github.com/keiyoushi/extensions/releases/download/808890d/tachiyomi-en.mangamelon-v1.6.1.apk|aedbd5ba3e3a092a381779f0e6ed610e630799070c1f032c5668f7455970d9aa
baozimanhua|https://github.com/keiyoushi/extensions/releases/download/4277105/tachiyomi-zh.baozimanhua-v1.6.29.apk|7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec
measurement/hayalistic|https://github.com/keiyoushi/extensions/releases/download/66535bd/tachiyomi-tr.hayalistic-v1.6.59.apk|57ebc2b3f9c0e2add4b8d1fe38069d2d216f9ee40f434653319da6284a47334c
measurement/eternalmangas|https://github.com/keiyoushi/extensions/releases/download/a76c957-1/tachiyomi-es.eternalmangas-v1.6.28.apk|6325059f3d45e2b727268cdae936f7bcb08f914c5852b40c9e7bd736e0b78be6
measurement/mangapandaonl|https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-en.mangapandaonl-v1.6.36.apk|00ba5d0cfd65132b6feffee60b7c8d5eca23c4ce4bd5687c7908e6c9f15a3166
tuttoanimemanga|https://github.com/keiyoushi/extensions/releases/download/a76c957-1/tachiyomi-it.tuttoanimemanga-v1.6.10.apk|e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3
measurement/nhentaixxx|https://github.com/keiyoushi/extensions/releases/download/66535bd/tachiyomi-all.nhentaixxx-v1.6.10.apk|ecb3b01ecfe4987e704a517f33bdb173080d3aa4cae06e7b0925a648a52ac4ef
measurement/foolslidecustomizable|https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-all.foolslidecustomizable-v1.6.6.apk|d45b6d44760cb0465cc7be317d6d1b899c778bb9d7c02d03fb6c2c141dfa137e
measurement/doctruyen3q|https://github.com/keiyoushi/extensions/releases/download/a18924b/tachiyomi-vi.doctruyen3q-v1.6.38.apk|3fe67ce34b42c4cb7b193a9536a27ae1b3f41805a866489e82797f56aad4c0a0
measurement/readmanga|https://github.com/keiyoushi/extensions/releases/download/a76c957-2/tachiyomi-ru.readmanga-v1.6.89.apk|c19c626ca9e34e113ab871aadfe19566a441669644f77a38793a0dd5dab7a00a
measurement/sssscanlator|https://github.com/keiyoushi/extensions/releases/download/4277105/tachiyomi-pt.sssscanlator-v1.6.59.apk|2d7dfad2d4d293c58414b8905c6bcf454bcfb1a2bb6650a50d7480b0b9597883
measurement/komikcast|https://github.com/keiyoushi/extensions/releases/download/01cba61/tachiyomi-id.komikcast-v1.6.83.apk|9420cd59844854ccad0a95353749b0ab41c9ddb797a6f43025fb1ddb4652c3ac
measurement/pixivcomic|https://github.com/keiyoushi/extensions/releases/download/acab221/tachiyomi-ja.pixivcomic-v1.6.4.apk|86efecdc38f5aca875da0abd5e6f2a8449ca3b06682a3c81f262fab787bb3d71
mangasoriginesfr|https://github.com/keiyoushi/extensions/releases/download/66535bd/tachiyomi-fr.mangasoriginesfr-v1.6.58.apk|b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b
measurement/mangaplus|https://github.com/keiyoushi/extensions/releases/download/a76c957-0/tachiyomi-all.mangaplus-v1.6.65.apk|a9211fc852cb602107e0d6f8657c2fc7ae8154fc391c386b0a3f79e3f48d4126
measurement/komga|https://github.com/keiyoushi/extensions/releases/download/66535bd/tachiyomi-all.komga-v1.6.69.apk|a711b134300ddec36fc60c8ec1a224a2593b44abae81b53e26436624dfef13cb
measurement/xcomic|https://github.com/keiyoushi/extensions/releases/download/acab221/tachiyomi-all.xcomic-v1.6.4.apk|dc494cc99138191f17022c173e43e90689640cf5e5fa23de28ef6f557986ca80
LOCKED_REAL_APKS

# Small vendored Apache-2.0 Android Open Source Project apksig conformance
# fixtures, restored from one pinned upstream revision. They cover signature
# schemes and malformed inputs absent from the real-extension sample.
while IFS='|' read -r name url expected; do
  [[ -n "$name" ]] || continue
  download_gitiles "$name" "$url" "$expected"
done <<'LOCKED_AOSP_APKS'
aosp-v3-original|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/golden-aligned-v3-out.apk?format=TEXT|6e606307a39c826330db293a63c677566265d593bcb9b5c6fa58b34f86102668
aosp-v3-lineage|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/golden-aligned-v3-lineage-out.apk?format=TEXT|e2f5131444fdefb60614ae48c5cd0092ccddd7eceb75b13a349045c9acad8632
aosp-v1|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/golden-aligned-v1-out.apk?format=TEXT|b9513e617253cc5864bccd731adeae270861e690a8dae86c15b1ee2aa3f867f4
aosp-unsigned|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/empty-unsigned.apk?format=TEXT|8739c76e681f900923b900c9df0ef75cf421d39cabb54650c4b9ad19b6a76d85
aosp-v2-invalid-signature|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/v2-only-with-rsa-pkcs1-sha256-2048-sig-does-not-verify.apk?format=TEXT|ae2f6bf5ae1cf510cc871f0e81bf8577c986362717e91d3bccb63d642760d02e
aosp-v3-stripped|https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/v2v3-signed-v3-block-stripped.apk?format=TEXT|ba6b48842c845d1593f3f54104ab8457e7fafc930ce67d7e61d62eefdf201f95
LOCKED_AOSP_APKS

echo "==> Pinned corpus ready"

# Audit each APK when a release compat-audit binary is already present.
BIN="Packages/MihonCompatKit/.build/release/compat-audit"
if [[ -x "$BIN" ]]; then
  for apk in "${REAL_APKS[@]}"; do
    echo "==> Auditing $(basename "$apk")"
    "$BIN" inspect "$apk" | sed -n '1,12p'
  done
fi
