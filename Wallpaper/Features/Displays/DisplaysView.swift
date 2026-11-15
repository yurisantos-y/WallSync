import SwiftUI

struct DisplaysView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Displays"),
                subtitle: String(localized: "Choose one wallpaper for every display, or a different one for each, and see what each display is doing.")
            )

            globalAssignmentCard

            if coordinator.runtimeState.activeDisplays.isEmpty {
                WallpaperGlassCard {
                    ContentUnavailableView(
                        "No display found",
                        systemImage: "display",
                        description: Text("Connect a display, or wait a moment for the system to finish detecting it.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.runtimeState.activeDisplays) { display in
                        WallpaperPlacementEditor(display: display)
                    }
                }
            }
        }
    }

    private var globalAssignmentCard: some View {
        WallpaperSectionCard(
            String(localized: "All displays"),
            subtitle: String(localized: "Used on every display that has no wallpaper of its own.")
        ) {
            HStack(alignment: .top) {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    WallpaperStatusPill(
                        label: String(localized: "\(coordinator.runtimeState.activeDisplays.count) displays"),
                        color: .blue
                    )
                    WallpaperStatusPill(
                        label: String(localized: "\(coordinator.activeSessions.count) wallpapers running"),
                        color: .green
                    )
                }
            }

            Picker(
                "Wallpaper for all displays",
                selection: Binding<UUID?>(
                    get: { coordinator.globalAssetID() },
                    set: { coordinator.setGlobalAsset($0) }
                )
            ) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(coordinator.assets) { asset in
                    Text(asset.displayName).tag(Optional(asset.id))
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                WallpaperStatusPill(
                    label: coordinator.runtimeState.powerSource.localizedLabel,
                    color: coordinator.runtimeState.powerSource == .battery ? .orange : .green
                )
                WallpaperStatusPill(
                    label: String(localized: "Temperature: \(coordinator.runtimeState.thermalState.localizedLabel)"),
                    color: coordinator.runtimeState.thermalState == .nominal ? .green : .orange
                )

                if coordinator.runtimeState.isUserPaused {
                    WallpaperStatusPill(label: String(localized: "Paused by you"), color: .orange)
                }

                if !coordinator.runtimeState.fullscreenDisplayUUIDs.isEmpty {
                    WallpaperStatusPill(
                        label: String(localized: "\(coordinator.runtimeState.fullscreenDisplayUUIDs.count) in fullscreen"),
                        color: .orange
                    )
                }
            }
        }
    }
}
