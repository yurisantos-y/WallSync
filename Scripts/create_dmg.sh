#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/export/WallSync.app}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/release/WallSync.dmg}"
VOLUME_NAME="${VOLUME_NAME:-WallSync}"
STAGED_APP_NAME="${STAGED_APP_NAME:-$(basename "$APP_PATH")}"
DMG_SIGNING_IDENTITY="${DMG_SIGNING_IDENTITY:-${SIGNING_CERTIFICATE:-}}"
ICON_SOURCE_PATH="${ICON_SOURCE_PATH:-$APP_PATH/Contents/Resources/AppIcon.icns}"

[[ -d "$APP_PATH" ]] || { echo "App not found at $APP_PATH" >&2; exit 1; }
mkdir -p "$(dirname "$DMG_PATH")"

STAGING_DIR="$(mktemp -d "$TMPDIR/wallsync-dmg.XXXXXX")"
MOUNT_POINT="$(mktemp -d "$TMPDIR/wallsync-volume.XXXXXX")"
RW_DMG_PATH="$(mktemp "$TMPDIR/wallsync-rw.XXXXXX")"
rm -f "$RW_DMG_PATH"
RW_DMG_PATH="${RW_DMG_PATH}.dmg"
RW_DEVICE=""
DMG_OUTPUT_BASE="${DMG_PATH%.dmg}"
FINAL_DMG_PATH="${DMG_OUTPUT_BASE}.dmg"

cleanup() {
  if [[ -n "$RW_DEVICE" ]]; then
    hdiutil detach "$RW_DEVICE" -force >/dev/null 2>&1 || true
  fi
  if mount | grep -q "on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING_DIR" "$MOUNT_POINT"
  rm -f "$RW_DMG_PATH"
}

trap cleanup EXIT

apply_volume_icon() {
  local source_path="$1"
  local volume_path="$2"

  if [[ ! -f "$source_path" ]]; then
    echo "Warning: could not find icon source at $source_path" >&2
    return 0
  fi

  cp "$source_path" "$volume_path/.VolumeIcon.icns"
  xcrun SetFile -a C "$volume_path"
  xcrun SetFile -a V "$volume_path/.VolumeIcon.icns"
}

apply_file_icon() {
  local source_path="$1"
  local target_path="$2"
  local temp_icon_path
  local temp_resource_path

  if [[ ! -f "$source_path" ]]; then
    echo "Warning: could not find icon source at $source_path" >&2
    return 0
  fi

  temp_icon_path="$(mktemp "$TMPDIR/wallsync-icon.XXXXXX.icns")"
  temp_resource_path="$(mktemp "$TMPDIR/wallsync-icon-rsrc.XXXXXX")"

  cp "$source_path" "$temp_icon_path"
  /usr/bin/sips -i "$temp_icon_path" >/dev/null
  xcrun DeRez -only icns "$temp_icon_path" > "$temp_resource_path"
  xcrun Rez -append "$temp_resource_path" -o "$target_path"
  xcrun SetFile -a C "$target_path"

  rm -f "$temp_icon_path" "$temp_resource_path"
}

ditto "$APP_PATH" "$STAGING_DIR/$STAGED_APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$FINAL_DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$RW_DMG_PATH"

RW_DEVICE="$(
  hdiutil attach \
    -readwrite \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    "$RW_DMG_PATH" | awk '/^\/dev\// { device = $1 } END { print device }'
)"

if [[ -n "$RW_DEVICE" ]]; then
  apply_volume_icon "$ICON_SOURCE_PATH" "$MOUNT_POINT"
  sync
  hdiutil detach "$RW_DEVICE" >/dev/null
  RW_DEVICE=""
fi

hdiutil convert \
  "$RW_DMG_PATH" \
  -ov \
  -format UDZO \
  -o "$DMG_OUTPUT_BASE"

apply_file_icon "$ICON_SOURCE_PATH" "$FINAL_DMG_PATH"

if [[ -n "$DMG_SIGNING_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$DMG_SIGNING_IDENTITY" "$FINAL_DMG_PATH"
fi

echo "DMG ready at $FINAL_DMG_PATH"
