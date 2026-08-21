#!/usr/bin/env bash
# Downloads a small, diverse corpus of REAL current extension APKs for
# compatibility testing, then runs compat-audit over it.
#
# The corpus mixes extension styles: big JSON API source, multisrc generator,
# lib-1.6 source, etc. Extend `PKGS` as coverage grows.
set -euo pipefail
cd "$(dirname "$0")/.."

CORPUS="Tests/corpus"
mkdir -p "$CORPUS"
INDEX="$CORPUS/index.pb"

echo "==> Fetching keiyoushi store index"
curl -sL "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb" -o "$INDEX"

# Extract apkUrl per package with python (protobuf is length-delimited soup;
# a 20-line walker is more robust than a full parser here).
python3 - "$INDEX" "$CORPUS" << 'EOF'
import gzip, json, sys, urllib.request, os

index_path, corpus = sys.argv[1], sys.argv[2]
data = open(index_path, 'rb').read()
if data[:2] == b'\x1f\x8b':
    data = gzip.decompress(data)

def rv(b, i):
    v = 0; s = 0
    while True:
        x = b[i]; i += 1
        v |= (x & 0x7f) << s
        if not (x & 0x80): return v, i
        s += 7

def fields(b):
    i = 0
    while i < len(b):
        t, i = rv(b, i); f, wt = t >> 3, t & 7
        if wt == 0: v, i = rv(b, i); yield f, v
        elif wt == 2: l, i = rv(b, i); yield f, b[i:i+l]; i += l
        elif wt == 5: yield f, b[i:i+4]; i += 4
        elif wt == 1: yield f, b[i:i+8]; i += 8
        else: raise SystemExit('bad wire type')

WANT = [
    'eu.kanade.tachiyomi.extension.all.mangadex',
    'eu.kanade.tachiyomi.extension.all.akuma',
    'eu.kanade.tachiyomi.extension.en.batcave',
]
exts = None
for f, v in fields(data):
    if f == 101: exts = v
if exts is None: raise SystemExit('index has no inline extension list')

manifest = []
for f, v in fields(exts):
    if f != 1: continue
    pkg = apk = None
    for ff, vv in fields(v):
        if ff == 2: pkg = vv.decode()
        if ff == 3:
            for f3, v3 in fields(vv):
                if f3 == 1: apk = v3.decode()
    if pkg in WANT:
        manifest.append((pkg, apk))

for pkg, apk in manifest:
    name = pkg.split('.')[-1] + '.apk'
    dest = os.path.join(corpus, name)
    if os.path.exists(dest):
        print('have', name); continue
    print('fetching', name)
    urllib.request.urlretrieve(apk, dest)
json.dump([p for p, _ in manifest], open(os.path.join(corpus, 'manifest.json'), 'w'), indent=1)
print(f'corpus ready: {len(manifest)} APKs in {corpus}')
EOF

# Audit each APK if the compat-audit tool is built.
BIN=".build/x86_64-unknown-windows-msvc/release/compat-audit"
[ -x "$BIN" ] || BIN=".build/release/compat-audit"
[ -x "$BIN" ] && for apk in "$CORPUS"/*.apk; do
  echo "==> $(basename "$apk")"
  "$BIN" inspect "$apk" | sed -n '1,12p'
done
exit 0
