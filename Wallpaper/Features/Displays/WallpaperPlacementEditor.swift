import SwiftUI

struct WallpaperPlacementEditor: View {
    @Environment(AppCoordinator.self) private var coordinator

    let display: DisplayTarget

    var body: some View {
        WallpaperGlassCard(padding: 18, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.localizedName)
                            .font(.title3.weight(.semibold))
                        Text(verbatim: "\(Int(display.frame.width))x\(Int(display.frame.height)) • \(display.maximumFramesPerSecond) Hz")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if display.isPrimary {
                        WallpaperStatusPill(label: String(localized: "Main display"), color: .blue)
                    }
                }

                displayStatusRow

                VStack(alignment: .leading, spacing: 6) {
                    Text("Current wallpaper")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(effectiveAssetLabel)
                        .font(.headline)
                    Text(sourceLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Picker(
                    "Wallpaper",
                    selection: Binding<UUID?>(
                        get: { coordinator.hasDisplayOverride(for: display) ? coordinator.assignedAssetID(for: display) : nil },
                        set: { coordinator.assignAsset($0, to: display) }
                    )
                ) {
                    Text("Same as all displays").tag(Optional<UUID>.none)
                    ForEach(coordinator.assets) { asset in
                        Text(asset.displayName).tag(Optional(asset.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(coordinator.assets.isEmpty)
                .accessibilityLabel(Text("Wallpaper for \(display.localizedName)"))

                if !coordinator.playlists.isEmpty {
                    Picker(
                        "Playlist",
                        selection: Binding<UUID?>(
                            get: { coordinator.ownPlaylistID(for: display) },
                            set: { coordinator.activatePlaylist($0, on: display) }
                        )
                    ) {
                        Text("No playlist").tag(Optional<UUID>.none)
                        ForEach(coordinator.playlists) { playlist in
                            Text(playlist.name).tag(Optional(playlist.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(Text("Playlist for \(display.localizedName)"))
                }

                Picker(
                    "Scaling",
                    selection: Binding(
                        get: { coordinator.contentMode(for: display) },
                        set: { coordinator.updateContentMode($0, for: display) }
                    )
                ) {
                    Text("Fill screen").tag(WallpaperPlacement.ContentMode.aspectFill)
                    Text("Fit to screen").tag(WallpaperPlacement.ContentMode.aspectFit)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Scaling for \(display.localizedName)"))

                HStack {
                    Button("Use the wallpaper for all displays") {
                        coordinator.assignAsset(nil, to: display)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.hasDisplayOverride(for: display))

                    Spacer()

                    if let session = coordinator.session(for: display) {
                        Text(verbatim: "\(session.playbackState.localizedLabel) • \(session.modeReason == .none ? session.energyMode.localizedLabel : session.modeReason.localizedLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var effectiveAssetLabel: String {
        coordinator.effectiveAsset(for: display)?.displayName ?? String(localized: "No wallpaper chosen")
    }

    private var sourceLabel: String {
        switch coordinator.resolution.content(forDisplayUUID: display.displayUUID)?.source {
        case let .playlist(id)?:
            if let name = coordinator.playlist(withID: id)?.name {
                return String(localized: "From the playlist “\(name)”")
            }
        case .focus?:
            return String(localized: "Chosen by a Focus filter")
        default:
            break
        }

        if coordinator.hasDisplayOverride(for: display) {
            return String(localized: "Chosen for this display")
        }

        if coordinator.globalAssetID() != nil {
            return String(localized: "Using the wallpaper for all displays")
        }

        return String(localized: "No wallpaper for all displays is set")
    }

    private var displayStatusRow: some View {
        HStack(spacing: 8) {
            WallpaperStatusPill(
                label: coordinator.hasDisplayOverride(for: display)
                    ? String(localized: "Own wallpaper")
                    : String(localized: "All displays"),
                color: coordinator.hasDisplayOverride(for: display) ? .blue : .gray
            )

            if coordinator.isDisplayFullscreen(display) {
                WallpaperStatusPill(label: String(localized: "Fullscreen app"), color: .orange)
            }

            if let session = coordinator.session(for: display) {
                WallpaperStatusPill(label: session.playbackState.localizedLabel, color: session.playbackState.color)
                if session.modeReason != .none {
                    WallpaperStatusPill(label: session.modeReason.localizedLabel, color: session.energyMode.color)
                }
            } else {
                WallpaperStatusPill(label: String(localized: "Not running"), color: .gray)
            }
        }
    }
}
