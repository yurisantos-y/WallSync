# WallSync

Copyright (c) 2026 Yuri Santos. All rights reserved.

WallSync is a macOS app project for managing animated wallpapers across displays.

## What it does

- Plays a video as the desktop wallpaper on one or more displays.
- Decodes each video once, however many displays show it, so displays are
  always on the same frame.
- Stops decoding whenever nobody can see the desktop: covered desktop,
  fullscreen app, locked screen, screen saver, sleeping displays, another
  user in front.
- Copies suitable videos as they are; converts the rest to hardware-decodable
  HEVC sized for the largest connected display. HDR and 10-bit are preserved.
- Per-wallpaper speed from 0.25× to 1×; slower playback decodes
  proportionally fewer frames.
- Adjustable dimming and tint, with an optional extra amount in dark mode.
- Loop editor: trim, crossfade the end into the beginning, automatic
  suggestion of loop points. Logo and mark removal. Both are written into
  the optimized rendition once and cost nothing during playback.
- One video stretched across several displays, still decoded once.
- Playlists that advance by interval, time of day or light / dark
  appearance, driven by a single timer that only exists while a desktop is
  visible.
- Quick switching from the menu bar, Shortcuts actions and a Focus filter.
- English and Brazilian Portuguese.

## Project structure

- `Wallpaper/`: app source code
  - `Core/Domain`, `Core/Policies`, `Core/Protocols`: pure, testable types
    (energy policy, optimization planner, reconciliation, cleanup rules,
    the resolver that decides what each display shows, playlist schedule,
    panorama geometry, loop-point and logo-removal maths)
  - `Infrastructure/`: AVFoundation, AppKit, Metal frame processing used
    by the optimizer, storage and system integration
  - `Features/`: SwiftUI screens (library, editor, displays, playlists,
    settings, diagnostics) and the App Intents
  - `App/`: coordinator, session manager, menu bar item
- `Tests/Unit/`: unit tests, session-manager tests with test doubles, and
  integration tests that synthesize short clips at run time
- `Scripts/`: build, export, notarization, and release helpers
- `Distribution/`: release notes and `PERFORMANCE.md` (how to measure)

## Development

Open `Wallpaper.xcodeproj` in Xcode and run the `Wallpaper` scheme on macOS 14
or later. From the command line:

```bash
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The tests are hosted in the app but never start wallpapers or touch your
library. Tests that drive the real media pipeline can be skipped with
`TEST_RUNNER_SKIP_MEDIA_TESTS=1`.

After adding, moving or deleting source files, run `./Scripts/sync_project.rb`
(needs the `xcodeproj` gem). It updates the project in place and keeps build
settings and scheme references intact.

User-facing text lives in `Wallpaper/Resources/Localizable.xcstrings`
(English source, Brazilian Portuguese translation). Every new string needs
both.

CI (`.github/workflows/ci.yml`) builds and runs the tests on every push and
pull request.

## Diagnostics and performance

Settings › Diagnostics shows what every display is doing and why. Logs use the
subsystem `com.yurisantos.wallpaper`. See `Distribution/PERFORMANCE.md` for how
to verify energy use, sync and "no decoding when unseen" with Instruments.

## Distribution

See `Distribution/README.md` for the Developer ID, notarization, and DMG release flow.

## License

WallSync is free to use, but it is proprietary software. The source code, binaries, branding, and related materials are not open source and may not be redistributed, modified, or sublicensed without prior written permission.

See `EULA.md` for the full end user license agreement.
