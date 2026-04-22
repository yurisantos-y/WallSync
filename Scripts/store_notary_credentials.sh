#!/bin/zsh

set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-wallpaper-notary}"
APPLE_ID="${APPLE_ID:?Set APPLE_ID to your Apple account email.}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Apple Team ID.}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD to your app-specific password.}"

xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD"

echo "Stored notarytool credentials in keychain profile $NOTARY_PROFILE"
