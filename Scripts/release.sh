#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"
NOTARY_PROFILE="${NOTARY_PROFILE:-wallpaper-notary}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
APP_PATH="$ROOT_DIR/dist/export/WallSync.app"
ZIP_PATH="$ROOT_DIR/dist/notarization/WallSync.zip"
DMG_PATH="$ROOT_DIR/dist/release/WallSync.dmg"

"$ROOT_DIR/Scripts/archive.sh"
"$ROOT_DIR/Scripts/export_developer_id.sh"
"$ROOT_DIR/Scripts/package_app_zip.sh"
"$ROOT_DIR/Scripts/notarize.sh" "$ZIP_PATH"
xcrun stapler staple "$APP_PATH"
"$ROOT_DIR/Scripts/create_dmg.sh"
"$ROOT_DIR/Scripts/notarize.sh" "$DMG_PATH"
"$ROOT_DIR/Scripts/verify_gatekeeper.sh" "$APP_PATH"

echo "Release pipeline completed. Final DMG: $DMG_PATH"
echo "Using notary profile: $NOTARY_PROFILE"
echo "Using signing certificate hint: $SIGNING_CERTIFICATE"
