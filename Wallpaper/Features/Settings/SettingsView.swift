import AppKit
import SwiftUI

/// Every preference on one page, grouped by the question it answers. The
/// last groups are the diagnostics: what each display is doing and why.
struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var didCopy = false

    private var preferences: UserPreferences { coordinator.preferences }
    private var dimming: DimmingSettings { coordinator.preferences.dimming }

    var body: some View {
        Form {
            startupSection
            dimmingSection
            qualitySection
            pauseSection
            batterySection
            diagnosticsSections
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: coordinator.activeSessions) {
            didCopy = false
        }
    }

    private func footnote(_ text: Text) -> some View {
        text
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section("Startup") {
            Toggle(
                isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { coordinator.updateLaunchAtLogin($0) }
                )
            ) {
                Text("Open WallSync at login")
                if coordinator.startupLoginState == .requiresApproval {
                    Text("Waiting for approval in System Settings")
                        .foregroundStyle(.orange)
                }
            }

            Toggle(
                "Start wallpapers when the app opens",
                isOn: Binding(
                    get: { preferences.startOnLaunch },
                    set: { coordinator.updateStartOnLaunch($0) }
                )
            )
        }
    }

    // MARK: - Dimming

    private var dimmingSection: some View {
        Section {
            Slider(
                value: Binding(
                    get: { dimming.amount },
                    set: { value in coordinator.updateDimming { $0.amount = value } }
                ),
                in: 0...DimmingSettings.maximum,
                step: 0.05
            ) {
                Text("Dimming")
                Text(dimming.amount.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .accessibilityValue(Text(dimming.amount.formatted(.percent.precision(.fractionLength(0)))))

            Toggle(
                isOn: Binding(
                    get: { dimming.dimMoreInDarkMode },
                    set: { value in coordinator.updateDimming { $0.dimMoreInDarkMode = value } }
                )
            ) {
                Text("Dim more in dark mode")
                Text("Adds extra dimming while macOS uses the dark appearance, and removes it in the light appearance.")
            }

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
            }
        } header: {
            Text("Dimming")
        } footer: {
            footnote(Text("Darkens every wallpaper so icons and widgets stay easy to read. Each wallpaper can have its own value in the library."))
        }
    }

    // MARK: - Quality

    private var qualitySection: some View {
        Section {
            Picker(
                "Playback quality",
                selection: Binding(
                    get: { preferences.playbackQuality },
                    set: { coordinator.updatePlaybackQuality($0) }
                )
            ) {
                Text("Efficiency (up to 30 fps)").tag(UserPreferences.PlaybackQuality.efficiency)
                Text("Smoothness (up to 60 fps)").tag(UserPreferences.PlaybackQuality.smooth)
            }
        } header: {
            Text("Playback quality")
        } footer: {
            footnote(Text("Efficiency uses the least energy. Smoothness keeps up to 60 frames per second and roughly doubles the decoding work; on battery, 60 fps videos are shown as a still frame when “Reduce activity on battery” is on."))
        }
    }

    // MARK: - Energy

    private var pauseSection: some View {
        Section {
            Toggle(
                "Pause when the desktop is completely covered",
                isOn: Binding(
                    get: { preferences.pauseWhenOccluded },
                    set: { coordinator.updatePauseWhenOccluded($0) }
                )
            )

            Toggle(
                "Pause while an app is in fullscreen",
                isOn: Binding(
                    get: { preferences.pauseWhenFullscreen },
                    set: { coordinator.updatePauseWhenFullscreen($0) }
                )
            )

            Toggle(
                isOn: Binding(
                    get: { preferences.pauseWhenReduceMotion },
                    set: { coordinator.updatePauseWhenReduceMotion($0) }
                )
            ) {
                Text("Show a still frame when Reduce Motion is on")
                Text("Follows the Reduce Motion setting in System Settings › Accessibility › Display.")
            }
        } header: {
            Text("Energy")
        } footer: {
            footnote(Text("The wallpaper always stops while the screen is locked, the displays are asleep or the screen saver is running. These options add to that."))
        }
    }

    private var batterySection: some View {
        Section("On battery") {
            Toggle(
                isOn: Binding(
                    get: { preferences.reduceOnBattery },
                    set: { coordinator.updateReduceOnBattery($0) }
                )
            ) {
                Text("Reduce activity on battery")
                Text("Demanding videos, such as 60 fps ones, show a still frame.")
            }

            Toggle(
                isOn: Binding(
                    get: { preferences.fallbackMode == .batterySaver },
                    set: { coordinator.updateFallbackMode($0 ? .batterySaver : .balanced) }
                )
            ) {
                Text("Animate only the main display")
                Text("The other displays show a still frame.")
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSections: some View {
        Section {
            row(Text("Version"), AppCoordinator.appVersion)
            row(Text("Power source"), coordinator.runtimeState.powerSource.localizedLabel)
            row(
                Text("Low Power Mode"),
                coordinator.runtimeState.lowPowerMode ? String(localized: "On") : String(localized: "Off")
            )
            row(Text("Thermal state"), coordinator.runtimeState.thermalState.localizedLabel)
        } header: {
            HStack {
                Text("Diagnostics")
                Spacer()
                Button(didCopy ? String(localized: "Copied") : String(localized: "Copy summary")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(coordinator.diagnosticsSummary(), forType: .string)
                    didCopy = true
                }
                .controlSize(.small)
                .help(Text("Copies a text report of the current state to the clipboard."))
            }
        }

        ForEach(coordinator.runtimeState.activeDisplays) { display in
            Section(display.localizedName) {
                if let session = coordinator.session(for: display) {
                    row(Text("Energy mode"), session.energyMode.localizedLabel)
                    row(Text("Reason"), session.modeReason.localizedLabel)
                    row(Text("Playback"), session.playbackState.localizedLabel)
                    row(Text("Video source"), session.playbackSource.localizedLabel)
                    row(Text("Decoded stream"), DiagnosticsSummary.videoDescription(for: session))
                } else {
                    Text("No active session")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: Text, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        } label: {
            title
        }
    }
}
