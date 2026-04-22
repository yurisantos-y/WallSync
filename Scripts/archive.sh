#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Wallpaper.xcodeproj}"
SCHEME="${SCHEME:-Wallpaper}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/dist/archive/Wallpaper.xcarchive}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  clean archive

echo "Archive ready at $ARCHIVE_PATH"
