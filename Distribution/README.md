# WallSync distribution

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
NOTARY_PROFILE="wallpaper-notary" ./Scripts/notarize.sh dist/notarization/WallSync.zip
```

Create DMG:

```bash
SIGNING_CERTIFICATE="Developer ID Application" ./Scripts/create_dmg.sh
```

Verify:

```bash
./Scripts/verify_gatekeeper.sh dist/export/WallSync.app
```

## Notes

- The scripts expect a real Apple Team ID via `DEVELOPMENT_TEAM`.
- `notarytool` is the current Apple-recommended notarization path for custom workflows.
- The release script staples the app after the ZIP notarization and staples the DMG after the DMG notarization so both offline install and offline first-launch have a safer path.
- The generated installer now defaults to `dist/release/WallSync.dmg`, mounts as `WallSync`, and exposes `WallSync.app` to the user.
- If you add, move or delete source files, update the project with `./Scripts/sync_project.rb`. It edits the existing project in place. `./Scripts/generate_project.rb` rebuilds the project from scratch and discards hand-tuned build settings (team, coverage flags), so use it only as a last resort.

## Sandbox entitlements

`Wallpaper/Resources/Wallpaper.entitlements` declares:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-only` — read the videos the user picks or drops
- `com.apple.security.files.bookmarks.app-scope` — keep access to those videos across launches (needed to re-optimize from the original and to fall back to it)

## Pre-release checklist (needs a signed, sandboxed build on real hardware)

Unit tests cannot cover these; run them on the exported app before shipping:

1. Import a video, quit, relaunch, and confirm it still plays. Then delete the optimized copy from `~/Library/Containers/<bundle id>/Data/Library/Application Support/Wallpaper/OptimizedVideos` while the app is closed and relaunch: it must play from the original file (security-scoped bookmark round trip).
2. Upgrade over a previous release with an existing library: assets, placements and preferences must survive, old PNG posters must still show, and leaked files in `OptimizedVideos/` and `Posters/` must be gone after launch.
3. Run the scenarios in `PERFORMANCE.md` (one display, several displays with the same video, covered desktop, fullscreen, locked, display asleep, battery, sleep/wake).
4. Import an HDR (HLG or PQ) 10-bit clip on an HDR display: it must stay HDR, and its poster must not look washed out.
5. Check the interface in English and in Portuguese (Brazil), and the menu bar icon in light and dark mode.

## Data locations

All data stays in `Application Support/Wallpaper` inside the app container (the directory keeps the project's original name; renaming it would need a migration): `assets.json`, `placements.json`, `bookmarks.json`, `OptimizedVideos/`, `Posters/`. Preferences are in `UserDefaults` under `wallpaper.preferences`. A damaged JSON file is renamed to `<name>.corrupt-<timestamp>.json` and the app starts with an empty one.
