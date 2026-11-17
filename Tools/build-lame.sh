#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-$ROOT/.build/lame}"
ARCHIVE="$ROOT/Vendor/LAME/lame-3.100.tar.gz"
EXPECTED="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then echo "Unexpected source checksum." >&2; exit 1; fi
mkdir -p "$SCRATCH"
tar -xzf "$ARCHIVE" -C "$SCRATCH"
SOURCE="$SCRATCH/lame-3.100"
# The upstream export list includes legacy/decoder symbols that are absent in
# an encoder-only build. Remove only those exports for the modern Darwin linker.
python3 - "$SOURCE/include/libmp3lame.sym" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
p.write_text("\n".join(x for x in lines if not x.startswith(("hip_", "lame_decode")) and x != "lame_init_old") + "\n")
PY
cd "$SOURCE"
CFLAGS="-O2 -std=gnu99 -Wno-implicit-function-declaration -mmacosx-version-min=14.0" \
LDFLAGS="-mmacosx-version-min=14.0" \
./configure --prefix="$SCRATCH/local" --disable-frontend --disable-decoder \
    --disable-static --enable-shared --disable-nasm --disable-dependency-tracking
make -j4
cp libmp3lame/.libs/libmp3lame.0.dylib "$ROOT/Vendor/LAME/"
install_name_tool -id @rpath/libmp3lame.0.dylib "$ROOT/Vendor/LAME/libmp3lame.0.dylib"
codesign --force --sign - "$ROOT/Vendor/LAME/libmp3lame.0.dylib"
