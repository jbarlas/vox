#!/usr/bin/env bash
# Notarizes and staples dist/Vox.app.
#
# Requires a Developer ID-signed build (scripts/sign.sh with DEVELOPER_ID set)
# and either a stored notarytool keychain profile or Apple ID credentials:
#
#   NOTARY_PROFILE=vox ./scripts/notarize.sh
#   APPLE_ID=... TEAM_ID=... APP_PASSWORD=... ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Vox.app"
ARCHIVE="$ROOT/dist/Vox.zip"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run: make app && make sign" >&2
  exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "error: set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD." >&2
  exit 1
fi

echo "==> Zipping for submission"
rm -f "$ARCHIVE"
# ditto (not zip) preserves the bundle's symlinks and extended attributes.
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Submitting to Apple"
xcrun notarytool submit "$ARCHIVE" "${CREDENTIALS[@]}" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo "==> Notarized $APP"
