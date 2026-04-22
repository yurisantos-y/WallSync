#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/dist/archive/Wallpaper.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/dist/export}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-1}"

[[ -d "$ARCHIVE_PATH" ]] || { echo "Archive not found at $ARCHIVE_PATH" >&2; exit 1; }
mkdir -p "$EXPORT_PATH"

XCODEBUILD_FLAGS=()
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  XCODEBUILD_FLAGS+=("-allowProvisioningUpdates")
fi

TEMP_PLIST="$(mktemp "$TMPDIR/wallpaper-export-options.XXXXXX.plist")"
trap 'rm -f "$TEMP_PLIST"' EXIT

cat > "$TEMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERTIFICATE}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$TEMP_PLIST" \
  "${XCODEBUILD_FLAGS[@]}"

echo "Developer ID export ready at $EXPORT_PATH"
