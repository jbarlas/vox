#!/usr/bin/env bash
# Signs dist/Vox.app (or $VOX_APP_BUNDLE) (and the CLI, if built).
#
# Ad-hoc signs by default; changed ad-hoc builds can lose privacy grants.
# Use CODE_SIGN_IDENTITY for a reusable local signing certificate, or
# DEVELOPER_ID for a distributable, notarizable build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${VOX_APP_BUNDLE:-$ROOT/dist/Vox.app}"
ENTITLEMENTS="$ROOT/Resources/Vox.entitlements"
IDENTITY="${DEVELOPER_ID:-${CODE_SIGN_IDENTITY:--}}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run: make app" >&2
  exit 1
fi

EXTRA_FLAGS=()
if [[ -n "${DEVELOPER_ID:-}" && "$IDENTITY" != "-" ]]; then
  # The hardened runtime and a secure timestamp are required for notarization,
  # and rejected for ad-hoc signatures.
  EXTRA_FLAGS+=(--options runtime --timestamp)
fi

if [[ -x "$APP/Contents/MacOS/vox-cli" ]]; then
  codesign --force --sign "$IDENTITY" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/vox-cli"
fi

codesign --force --sign "$IDENTITY" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
  --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Signed $APP with identity: $IDENTITY"
