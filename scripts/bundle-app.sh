#!/usr/bin/env bash
# Assembles dist/Vox.app around the VoxApp executable built by SwiftPM.
#
# whisper.cpp is linked statically (see build-whisper.sh), so there are no
# dylibs to copy; ffmpeg is optional and intentionally not vendored — the
# microphone path converts audio natively via AVAudioConverter.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
EXECUTABLE="$ROOT/.build/$CONFIGURATION/VoxApp"
APP="$ROOT/dist/Vox.app"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: $EXECUTABLE not found. Run: make app" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/Vox"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ship the CLI inside the bundle when it has been built, so an app-only install
# can still expose `vox` (see README for the symlink step).
if [[ -x "$ROOT/.build/$CONFIGURATION/vox" ]]; then
  cp "$ROOT/.build/$CONFIGURATION/vox" "$APP/Contents/MacOS/vox"
fi

echo "==> Built $APP"
