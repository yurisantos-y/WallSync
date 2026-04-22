#!/bin/zsh

set -euo pipefail

ARTIFACT_PATH="${1:-${ARTIFACT_PATH:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-wallpaper-notary}"

[[ -n "$ARTIFACT_PATH" ]] || { echo "Usage: notarize.sh <artifact-path>" >&2; exit 1; }
[[ -e "$ARTIFACT_PATH" ]] || { echo "Artifact not found at $ARTIFACT_PATH" >&2; exit 1; }

xcrun notarytool submit "$ARTIFACT_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$ARTIFACT_PATH"

echo "Notarized and stapled $ARTIFACT_PATH"
