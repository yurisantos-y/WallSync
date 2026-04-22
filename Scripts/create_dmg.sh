#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/export/Wallpaper.app}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/release/Wallpaper.dmg}"
VOLUME_NAME="${VOLUME_NAME:-Wallpaper}"
DMG_SIGNING_IDENTITY="${DMG_SIGNING_IDENTITY:-${SIGNING_CERTIFICATE:-}}"

[[ -d "$APP_PATH" ]] || { echo "App not found at $APP_PATH" >&2; exit 1; }
mkdir -p "$(dirname "$DMG_PATH")"

STAGING_DIR="$(mktemp -d "$TMPDIR/wallpaper-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "$DMG_SIGNING_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$DMG_SIGNING_IDENTITY" "$DMG_PATH"
fi

echo "DMG ready at $DMG_PATH"
