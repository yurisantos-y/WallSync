import SwiftUI

struct StartupSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Startup"),
                subtitle: String(localized: "Open WallSync automatically when you log in to your Mac.")
            )

            WallpaperSectionCard(
                String(localized: "Open at login"),
                subtitle: String(localized: "When on, WallSync starts together with your user session.")
            ) {
                Toggle(
                    "Open WallSync at login",
                    isOn: Binding(
                        get: { coordinator.preferences.launchAtLogin },
                        set: { coordinator.updateLaunchAtLogin($0) }
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WallpaperSectionCard(
                String(localized: "Current status"),
                subtitle: String(localized: "What macOS last reported for the login item.")
            ) {
                LabeledContent("Status") {
                    WallpaperStatusPill(label: statusLabel, color: statusColor)
                }
            }
        }
    }

    private var statusLabel: String {
        switch coordinator.startupLoginState {
        case .enabled:
            return String(localized: "On")
        case .disabled:
            return String(localized: "Off")
        case .requiresApproval:
            return String(localized: "Waiting for approval in System Settings")
        }
    }

    private var statusColor: Color {
        switch coordinator.startupLoginState {
        case .enabled:
            return .green
        case .disabled:
            return .gray
        case .requiresApproval:
            return .orange
        }
    }
}
