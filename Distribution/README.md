# Wallpaper distribution

This project is prepared for outside-the-Mac-App-Store distribution with:

- App Sandbox enabled
- Developer ID export
- notarization through `xcrun notarytool`
- stapling for both the `.app` and the final `.dmg`

## Prerequisites

1. Install Xcode and log in with the Apple Developer account that owns the Developer ID certificate.
2. Make sure the machine has a valid `Developer ID Application` certificate in Keychain Access.
3. Store a notarytool keychain profile once:

```bash
APPLE_ID="you@example.com" \
TEAM_ID="ABCDE12345" \
APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
NOTARY_PROFILE="wallpaper-notary" \
./Scripts/store_notary_credentials.sh
```

## One-shot release pipeline

```bash
DEVELOPMENT_TEAM="ABCDE12345" \
NOTARY_PROFILE="wallpaper-notary" \
SIGNING_CERTIFICATE="Developer ID Application" \
./Scripts/release.sh
```

This pipeline performs:

1. `xcodebuild archive`
2. `xcodebuild -exportArchive` with `method=developer-id`
3. ZIP packaging for app notarization
4. app notarization and stapling
5. DMG packaging
6. DMG notarization and stapling
7. Gatekeeper verification with `spctl` and `codesign`

## Step-by-step commands

Archive:

```bash
DEVELOPMENT_TEAM="ABCDE12345" ./Scripts/archive.sh
```

Export Developer ID app:

```bash
DEVELOPMENT_TEAM="ABCDE12345" ./Scripts/export_developer_id.sh
```

ZIP for notarization:

```bash
./Scripts/package_app_zip.sh
```

Notarize:

```bash
NOTARY_PROFILE="wallpaper-notary" ./Scripts/notarize.sh dist/notarization/Wallpaper.zip
```

Create DMG:

```bash
SIGNING_CERTIFICATE="Developer ID Application" ./Scripts/create_dmg.sh
```

Verify:

```bash
./Scripts/verify_gatekeeper.sh dist/export/Wallpaper.app
```

## Notes

- The scripts expect a real Apple Team ID via `DEVELOPMENT_TEAM`.
- `notarytool` is the current Apple-recommended notarization path for custom workflows.
- The release script staples the app after the ZIP notarization and staples the DMG after the DMG notarization so both offline install and offline first-launch have a safer path.
- If you add new Swift files to the project, regenerate the project file with `./Scripts/generate_project.rb`.
