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
