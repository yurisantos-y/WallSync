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

            if !coordinator.playlists.isEmpty {
                Picker(
                    "Playlist for all displays",
                    selection: Binding<UUID?>(
                        get: { coordinator.globalPlaylistID },
                        set: { coordinator.activatePlaylist($0) }
                    )
                ) {
                    Text("No playlist").tag(Optional<UUID>.none)
                    ForEach(coordinator.playlists) { playlist in
                        Text(playlist.name).tag(Optional(playlist.id))
                    }
                }
                .pickerStyle(.menu)
                .help(Text("A playlist changes the wallpaper by itself. The wallpaper chosen above is used while the playlist has nothing to show."))
            }

            panoramaControls

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

extension DisplaysView {
    /// Displays that show the "all displays" wallpaper, i.e. the ones a
    /// panorama would span.
    private var spannedDisplays: [DisplayTarget] {
        coordinator.runtimeState.activeDisplays.filter { !coordinator.hasDisplayOverride(for: $0) }
    }

    @ViewBuilder
    fileprivate var panoramaControls: some View {
        if let placement = coordinator.globalPlacement {
            let displays = spannedDisplays
            let asset = coordinator.assets.first { $0.id == placement.assetID }
            let slack = PanoramaLayout.hasSlack(
                displays: displays.map { PanoramaLayout.Display(id: $0.displayUUID, frame: $0.frame) },
                videoSize: asset?.pixelSize ?? .zero
            )

            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Stretch one video across the displays",
                    isOn: Binding(
                        get: { placement.spansDisplays },
                        set: { coordinator.updatePanorama(spansDisplays: $0) }
                    )
                )
                .disabled(displays.count < 2 && !placement.spansDisplays)
                .help(Text("Each display shows its own part of the same video, as if the screens were windows onto one picture. The video is still decoded only once."))

                if placement.spansDisplays {
                    if displays.count < 2 {
                        Text("Needs at least two displays using the wallpaper for all displays.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if slack.horizontal {
                            panoramaSlider(title: String(localized: "Horizontal position"), placement: placement, horizontal: true)
                        }
                        if slack.vertical {
                            panoramaSlider(title: String(localized: "Vertical position"), placement: placement, horizontal: false)
                        }
                    }
                }
            }
        }
    }

    private func panoramaSlider(title: String, placement: WallpaperPlacement, horizontal: Bool) -> some View {
        let offset = placement.panoramaOffset
        return HStack(spacing: 12) {
            Text(title)
                .frame(width: 150, alignment: .leading)
            Slider(
                value: Binding(
                    get: { horizontal ? offset.x : offset.y },
                    set: { coordinator.updatePanorama(offset: horizontal ? CGPoint(x: $0, y: offset.y) : CGPoint(x: offset.x, y: $0)) }
                ),
                in: -1...1
            )
            .accessibilityLabel(Text(title))
        }
    }
}
