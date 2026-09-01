#!/usr/bin/env bash
# Downloads a ggml whisper model into the Vox support directory.
#
# Deliberately independent of the built CLI so `make setup` can fetch a model
# even if the Swift build is broken, and so CI can pre-warm the cache.
set -euo pipefail

MODEL="${1:-small.en}"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
SUPPORT_DIR="${VOX_HOME:-$HOME/Library/Application Support/Vox}"
MODELS_DIR="$SUPPORT_DIR/models"
FILE="ggml-${MODEL}.bin"
DESTINATION="$MODELS_DIR/$FILE"

if [[ -f "$DESTINATION" ]]; then
  echo "$MODEL is already installed at $DESTINATION"
  exit 0
fi

mkdir -p "$MODELS_DIR"
echo "==> Downloading $FILE"
# Download to a temporary path so an interrupted transfer is never mistaken for
# an installed model.
TEMPORARY="$DESTINATION.partial"
trap 'rm -f "$TEMPORARY"' EXIT
curl -fL --progress-bar -o "$TEMPORARY" "$BASE_URL/$FILE"
mv "$TEMPORARY" "$DESTINATION"
trap - EXIT
echo "==> Installed $DESTINATION"
