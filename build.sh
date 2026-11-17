#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/dist/声流.app}"
SCRATCH="${BUILD_DIR:-$ROOT/.build}"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH/module-cache"
mkdir -p "$SCRATCH"
if [ ! -f "$ROOT/Vendor/LAME/libmp3lame.0.dylib" ]; then
    bash "$ROOT/Tools/build-lame.sh" "$SCRATCH/lame"
fi
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release --show-bin-path)"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources/LAME" "$DEST/Contents/Frameworks"
cp "$BIN/AudioLoom" "$DEST/Contents/MacOS/AudioLoom"
cp "$ROOT/Resources/Info.plist" "$DEST/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$DEST/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Vendor/LAME/libmp3lame.0.dylib" "$DEST/Contents/Frameworks/"
cp "$ROOT/Vendor/LAME/COPYING" "$ROOT/Vendor/LAME/README.md" "$ROOT/Vendor/LAME/lame-3.100.tar.gz" "$DEST/Contents/Resources/LAME/"
cp "$ROOT/Tools/build-lame.sh" "$DEST/Contents/Resources/LAME/build-lame.sh"
codesign --force --sign - "$DEST/Contents/Frameworks/libmp3lame.0.dylib"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$DEST"
echo "Built: $DEST"
