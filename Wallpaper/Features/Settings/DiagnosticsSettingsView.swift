import AppKit
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var didCopy = false

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Diagnostics"),
                subtitle: String(localized: "Live state of every display, to verify what is animating and why.")
            ) {
                Button(didCopy ? String(localized: "Copied") : String(localized: "Copy summary")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(coordinator.diagnosticsSummary(), forType: .string)
                    didCopy = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint(Text("Copies a text report of the current state to the clipboard."))
            }

            WallpaperSectionCard(String(localized: "System")) {
                VStack(alignment: .leading, spacing: 8) {
                    row(String(localized: "Version"), AppCoordinator.appVersion)
                    row(String(localized: "Power source"), coordinator.runtimeState.powerSource.localizedLabel)
                    row(
                        String(localized: "Low Power Mode"),
                        coordinator.runtimeState.lowPowerMode ? String(localized: "On") : String(localized: "Off")
                    )
                    row(String(localized: "Thermal state"), coordinator.runtimeState.thermalState.localizedLabel)
                }
            }

            if coordinator.runtimeState.activeDisplays.isEmpty {
                WallpaperGlassCard {
                    Text("No display found")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(coordinator.runtimeState.activeDisplays) { display in
                WallpaperSectionCard(display.localizedName) {
                    if let session = coordinator.session(for: display) {
                        VStack(alignment: .leading, spacing: 8) {
                            row(String(localized: "Energy mode"), session.energyMode.localizedLabel)
                            row(String(localized: "Reason"), session.modeReason.localizedLabel)
                            row(String(localized: "Playback"), session.playbackState.localizedLabel)
                            row(String(localized: "Video source"), session.playbackSource.localizedLabel)
                            row(String(localized: "Decoded stream"), DiagnosticsSummary.videoDescription(for: session))
                        }
                    } else {
                        Text("No active session")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: coordinator.activeSessions) {
            didCopy = false
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }
}
