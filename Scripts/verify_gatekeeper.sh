#!/bin/zsh

set -euo pipefail

TARGET_PATH="${1:-${TARGET_PATH:-}}"

[[ -n "$TARGET_PATH" ]] || { echo "Usage: verify_gatekeeper.sh <app-or-dmg-path>" >&2; exit 1; }
[[ -e "$TARGET_PATH" ]] || { echo "Target not found at $TARGET_PATH" >&2; exit 1; }

spctl --assess --type exec --verbose=4 "$TARGET_PATH"
codesign --verify --deep --strict --verbose=2 "$TARGET_PATH"

echo "Gatekeeper verification completed for $TARGET_PATH"
