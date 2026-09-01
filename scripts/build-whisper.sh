#!/usr/bin/env bash
# Builds the vendored whisper.cpp and installs a single merged static archive
# (libvox-whisper.a) plus headers under vendor/whisper.cpp/install.
#
# Merging every ggml/whisper archive into one keeps Package.swift's link flags
# stable across whisper.cpp releases, which split their libraries differently
# from version to version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT/vendor/whisper.cpp"
BUILD_DIR="$SOURCE_DIR/build"
INSTALL_DIR="$SOURCE_DIR/install"
MERGED="$INSTALL_DIR/lib/libvox-whisper.a"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: Vox targets macOS; whisper.cpp must be built there (found $(uname -s))." >&2
  exit 1
fi

for tool in cmake git; do
  command -v "$tool" >/dev/null || {
    echo "error: $tool is required. Install it with: brew install $tool" >&2
    exit 1
  }
done

if [[ ! -f "$SOURCE_DIR/CMakeLists.txt" ]]; then
  echo "==> Checking out the whisper.cpp submodule"
  git -C "$ROOT" submodule update --init --depth 1 vendor/whisper.cpp
fi

echo "==> Configuring whisper.cpp"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON

echo "==> Building whisper.cpp"
cmake --build "$BUILD_DIR" --config Release -j"$(sysctl -n hw.ncpu)"

echo "==> Installing headers and libraries"
cmake --install "$BUILD_DIR" --config Release

# The install step does not always carry every ggml header; the bridge needs
# whisper.h and whatever it includes.
mkdir -p "$INSTALL_DIR/include"
cp -f "$SOURCE_DIR/include/"*.h "$INSTALL_DIR/include/"
cp -f "$SOURCE_DIR/ggml/include/"*.h "$INSTALL_DIR/include/"

echo "==> Merging static archives into $(basename "$MERGED")"
rm -f "$MERGED"
# macOS still ships bash 3.2, so no mapfile here.
if [[ -z "$(find "$INSTALL_DIR/lib" -name '*.a' -print -quit)" ]]; then
  echo "error: whisper.cpp produced no static libraries; was BUILD_SHARED_LIBS left on?" >&2
  exit 1
fi
find "$INSTALL_DIR/lib" -name '*.a' -print0 | xargs -0 libtool -static -o "$MERGED"

echo "==> Done: $MERGED"
