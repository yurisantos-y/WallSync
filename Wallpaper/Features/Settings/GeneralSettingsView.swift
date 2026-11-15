import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "General"),
                subtitle: String(localized: "How WallSync behaves when it opens and how videos are prepared.")
            )

            WallpaperSectionCard(
                String(localized: "App behavior"),
                subtitle: String(localized: "Choose whether wallpapers start by themselves.")
            ) {
                Toggle(
                    "Start wallpapers when the app opens",
                    isOn: Binding(
                        get: { coordinator.preferences.startOnLaunch },
                        set: { coordinator.updateStartOnLaunch($0) }
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            dimmingCard

            WallpaperSectionCard(
                String(localized: "Playback quality"),
                subtitle: String(localized: "Applies to videos you import from now on. Videos in use are re-optimized in the background when a higher quality becomes possible.")
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(
                        "Playback quality",
                        selection: Binding(
                            get: { coordinator.preferences.playbackQuality },
                            set: { coordinator.updatePlaybackQuality($0) }
                        )
                    ) {
                        Text("Efficiency (up to 30 fps)").tag(UserPreferences.PlaybackQuality.efficiency)
                        Text("Smoothness (up to 60 fps)").tag(UserPreferences.PlaybackQuality.smooth)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityLabel(Text("Playback quality"))

                    Text("Efficiency uses the least energy. Smoothness keeps up to 60 frames per second and roughly doubles the decoding work; on battery, 60 fps videos are shown as a still frame when “Reduce activity on battery” is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension GeneralSettingsView {
    private var dimming: DimmingSettings { coordinator.preferences.dimming }

    fileprivate var dimmingCard: some View {
        WallpaperSectionCard(
            String(localized: "Dimming"),
            subtitle: String(localized: "Darkens every wallpaper so icons and widgets stay easy to read. Each wallpaper can have its own value in the library.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { dimming.amount },
                            set: { value in coordinator.updateDimming { $0.amount = value } }
                        ),
                        in: 0...DimmingSettings.maximum,
                        step: 0.05
                    ) {
                        Text("Dimming")
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Dimming"))
                    .accessibilityValue(Text(dimming.amount.formatted(.percent.precision(.fractionLength(0)))))

                    Text(dimming.amount.formatted(.percent.precision(.fractionLength(0))))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Divider()

                Toggle(
                    "Dim more in dark mode",
                    isOn: Binding(
                        get: { dimming.dimMoreInDarkMode },
                        set: { value in coordinator.updateDimming { $0.dimMoreInDarkMode = value } }
                    )
                )
                .help(Text("Adds extra dimming while macOS uses the dark appearance, and removes it in the light appearance."))

                Divider()

                HStack(spacing: 12) {
                    Toggle(
                        "Tint with a color",
                        isOn: Binding(
                            get: { dimming.tint != nil },
                            set: { value in
                                coordinator.updateDimming { $0.tint = value ? ($0.tint ?? RGBColor(red: 0.05, green: 0.08, blue: 0.2)) : nil }
                            }
                        )
                    )

                    if let tint = dimming.tint {
                        ColorPicker(
                            "Tint color",
                            selection: Binding(
                                get: { Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue) },
                                set: { color in
                                    guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                                    coordinator.updateDimming {
                                        $0.tint = RGBColor(
                                            red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent
                                        )
                                    }
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .accessibilityLabel(Text("Tint color"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
