import SwiftUI

struct EnergySettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Energy"),
                subtitle: String(localized: "How the wallpaper reacts to battery power, covered desktops and fullscreen apps.")
            )

            WallpaperSectionCard(
                String(localized: "Automatic policies"),
                subtitle: String(localized: "The wallpaper always stops while the screen is locked, the displays are asleep or the screen saver is running. These options add to that.")
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Reduce activity on battery",
                        isOn: Binding(
                            get: { coordinator.preferences.reduceOnBattery },
                            set: { coordinator.updateReduceOnBattery($0) }
                        )
                    )

                    Divider()

                    Toggle(
                        "Pause when the desktop is completely covered",
                        isOn: Binding(
                            get: { coordinator.preferences.pauseWhenOccluded },
                            set: { coordinator.updatePauseWhenOccluded($0) }
                        )
                    )

                    Divider()

                    Toggle(
                        "Pause while an app is in fullscreen",
                        isOn: Binding(
                            get: { coordinator.preferences.pauseWhenFullscreen },
                            set: { coordinator.updatePauseWhenFullscreen($0) }
                        )
                    )

                    Divider()

                    Toggle(
                        "Show a still frame when Reduce Motion is on",
                        isOn: Binding(
                            get: { coordinator.preferences.pauseWhenReduceMotion },
                            set: { coordinator.updatePauseWhenReduceMotion($0) }
                        )
                    )
                    .help(Text("Follows the Reduce Motion setting in System Settings › Accessibility › Display."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WallpaperSectionCard(
                String(localized: "Energy profile"),
                subtitle: String(localized: "Battery saver also keeps secondary displays on a still frame while on battery.")
            ) {
                Picker(
                    "Energy profile",
                    selection: Binding(
                        get: { coordinator.preferences.fallbackMode },
                        set: { coordinator.updateFallbackMode($0) }
                    )
                ) {
                    Text("Balanced").tag(UserPreferences.FallbackMode.balanced)
                    Text("Battery saver").tag(UserPreferences.FallbackMode.batterySaver)
                }
                .pickerStyle(.menu)
            }
        }
    }
}
