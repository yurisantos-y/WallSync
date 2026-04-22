#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/export/Wallpaper.app}"
ZIP_PATH="${ZIP_PATH:-$ROOT_DIR/dist/notarization/Wallpaper.zip}"

[[ -d "$APP_PATH" ]] || { echo "App not found at $APP_PATH" >&2; exit 1; }
mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "ZIP ready at $ZIP_PATH"
