import SwiftUI

/// What every display shows and what it is doing: a picture of the desk on
/// top, then one group per display. Each group answers three questions —
/// what is on it, why, and is it animating.
struct DisplaysView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private var displays: [DisplayTarget] { coordinator.runtimeState.activeDisplays }

    /// With a single display that follows the default there is only one
    /// thing to choose, so the two groups are shown as one.
    private var mergesDefaultIntoDisplay: Bool {
        displays.count == 1 && !coordinator.hasDisplayOverride(for: displays[0])
    }

    var body: some View {
        Group {
            if displays.isEmpty {
                ContentUnavailableView(
                    "No display found",
                    systemImage: "display",
                    description: Text("Connect a display, or wait a moment for the system to finish detecting it.")
                )
            } else {
                Form {
                    Section {
                        DisplayMap(displays: displays)
                            .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                    }

                    if mergesDefaultIntoDisplay {
                        DisplaySection(display: displays[0], usesDefault: true)
                    } else {
                        defaultSection
                        ForEach(displays) { display in
                            DisplaySection(display: display, usesDefault: false)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Displays")
    }

    private var defaultSection: some View {
        Section {
            DefaultWallpaperRows(noneLabel: Text("None"))
        } header: {
            Text("All displays")
        } footer: {
            Text("Used on every display that has no wallpaper of its own.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Default wallpaper

/// The rows that edit the wallpaper for all displays: what it shows, how it
/// is scaled and whether it stretches across the displays.
private struct DefaultWallpaperRows: View {
    @Environment(AppCoordinator.self) private var coordinator
    let noneLabel: Text

    private var source: Binding<WallpaperSource> {
        Binding(
            get: {
                if let id = coordinator.globalPlaylistID { return .playlist(id) }
                if let id = coordinator.globalAssetID() { return .asset(id) }
                return .none
            },
            set: { value in
                switch value {
                case .none: coordinator.setGlobalAsset(nil)
                case let .asset(id): coordinator.setGlobalAsset(id)
                case let .playlist(id): coordinator.activatePlaylist(id)
                }
            }
        )
    }

    /// Displays that show the "all displays" wallpaper, i.e. the ones a
    /// panorama would span.
    private var spannedDisplays: [DisplayTarget] {
        coordinator.runtimeState.activeDisplays.filter { !coordinator.hasDisplayOverride(for: $0) }
    }

    var body: some View {
        WallpaperSourcePicker(title: Text("Shows"), noneLabel: noneLabel, selection: source)
            .accessibilityLabel(Text("Wallpaper for all displays"))

        if let placement = coordinator.globalPlacement {
            if !placement.spansDisplays {
                ScalingPicker(
                    selection: Binding(
                        get: { coordinator.globalContentMode },
                        set: { coordinator.updateGlobalContentMode($0) }
                    )
                )
            }
            panoramaRows(placement: placement)
        }
    }

    @ViewBuilder
    private func panoramaRows(placement: WallpaperPlacement) -> some View {
        let displays = spannedDisplays
        if displays.count >= 2 || placement.spansDisplays {
            Toggle(
                isOn: Binding(
                    get: { placement.spansDisplays },
                    set: { coordinator.updatePanorama(spansDisplays: $0) }
                )
            ) {
                Text("Stretch one video across the displays")
                Text("Each display shows its own part of the same video, as if the screens were windows onto one picture. The video is still decoded only once.")
            }

            if placement.spansDisplays {
                if displays.count < 2 {
                    Text("Needs at least two displays using the wallpaper for all displays.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let asset = coordinator.assets.first { $0.id == placement.assetID }
                    let slack = PanoramaLayout.hasSlack(
                        displays: displays.map { PanoramaLayout.Display(id: $0.displayUUID, frame: $0.frame) },
                        videoSize: asset?.pixelSize ?? .zero
                    )
                    if slack.horizontal {
                        panoramaSlider(Text("Horizontal position"), placement: placement, horizontal: true)
                    }
                    if slack.vertical {
                        panoramaSlider(Text("Vertical position"), placement: placement, horizontal: false)
                    }
                }
            }
        }
    }

    private func panoramaSlider(_ title: Text, placement: WallpaperPlacement, horizontal: Bool) -> some View {
        let offset = placement.panoramaOffset
        return Slider(
            value: Binding(
                get: { horizontal ? offset.x : offset.y },
                set: { coordinator.updatePanorama(offset: horizontal ? CGPoint(x: $0, y: offset.y) : CGPoint(x: offset.x, y: $0)) }
            ),
            in: -1...1
        ) {
            title
        }
    }
}

private struct ScalingPicker: View {
    @Binding var selection: WallpaperPlacement.ContentMode

    var body: some View {
        Picker("Scaling", selection: $selection) {
            Text("Fill screen").tag(WallpaperPlacement.ContentMode.aspectFill)
            Text("Fit to screen").tag(WallpaperPlacement.ContentMode.aspectFit)
        }
    }
}

// MARK: - One display

private struct DisplaySection: View {
    @Environment(AppCoordinator.self) private var coordinator
    let display: DisplayTarget
    /// The display is the only one and follows the default: its group edits
    /// the default directly.
    let usesDefault: Bool

    private var hasOverride: Bool { coordinator.hasDisplayOverride(for: display) }

    private var source: Binding<WallpaperSource> {
        Binding(
            get: {
                guard hasOverride else { return .none }
                if let id = coordinator.ownPlaylistID(for: display), coordinator.playlist(withID: id) != nil {
                    return .playlist(id)
                }
                return coordinator.assignedAssetID(for: display).map(WallpaperSource.asset) ?? .none
            },
            set: { value in
                switch value {
                case .none: coordinator.assignAsset(nil, to: display)
                case let .asset(id): coordinator.assignAsset(id, to: display)
                case let .playlist(id): coordinator.activatePlaylist(id, on: display)
                }
            }
        )
    }

    var body: some View {
        Section {
            nowShowing

            if usesDefault {
                DefaultWallpaperRows(noneLabel: Text("None"))
            } else {
                WallpaperSourcePicker(title: Text("Shows"), noneLabel: Text("Same as all displays"), selection: source)
                    .disabled(coordinator.assets.isEmpty)
                    .accessibilityLabel(Text("Wallpaper for \(display.localizedName)"))

                if hasOverride {
                    ScalingPicker(
                        selection: Binding(
                            get: { coordinator.contentMode(for: display) },
                            set: { coordinator.updateContentMode($0, for: display) }
                        )
                    )
                    .accessibilityLabel(Text("Scaling for \(display.localizedName)"))
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(display.localizedName)
                if display.isPrimary, coordinator.runtimeState.activeDisplays.count > 1 {
                    Text("Main display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(verbatim: "\(Int(display.frame.width))×\(Int(display.frame.height)) · \(display.maximumFramesPerSecond) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Picture, name, where it comes from and what it is doing.
    private var nowShowing: some View {
        let asset = coordinator.effectiveAsset(for: display)
        let status = DisplayStatus.make(session: coordinator.session(for: display), hasWallpaper: asset != nil)

        return HStack(spacing: 12) {
            AssetThumbnail(asset: asset, cornerRadius: 6)
                .frame(width: 96)

            VStack(alignment: .leading, spacing: 3) {
                Text(asset?.displayName ?? String(localized: "No wallpaper chosen"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if asset != nil {
                    Text(sourceLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    DisplayStatusLabel(status: status)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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

        if hasOverride {
            return String(localized: "Chosen for this display")
        }
        return usesDefault
            ? String(localized: "Your wallpaper")
            : String(localized: "Using the wallpaper for all displays")
    }
}

// MARK: - Map

/// The displays drawn as they are arranged on the desk, each with the
/// picture of what it shows.
private struct DisplayMap: View {
    @Environment(AppCoordinator.self) private var coordinator
    let displays: [DisplayTarget]

    var body: some View {
        GeometryReader { proxy in
            let bounds = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = min(
                proxy.size.width / max(bounds.width, 1),
                proxy.size.height / max(bounds.height, 1)
            )
            let origin = CGPoint(
                x: (proxy.size.width - bounds.width * scale) / 2,
                y: (proxy.size.height - bounds.height * scale) / 2
            )

            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    // Screen frames have their origin at the bottom left.
                    let rect = CGRect(
                        x: origin.x + (display.frame.minX - bounds.minX) * scale,
                        y: origin.y + (bounds.maxY - display.frame.maxY) * scale,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    ).insetBy(dx: 2, dy: 2)

                    tile(for: display)
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: displays.count > 1 ? 170 : 150)
    }

    private func tile(for display: DisplayTarget) -> some View {
        let asset = coordinator.effectiveAsset(for: display)
        let status = DisplayStatus.make(session: coordinator.session(for: display), hasWallpaper: asset != nil)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        return ThumbnailImage(url: asset.flatMap(coordinator.thumbnailURL(for:)))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    StatusDot(color: status.color)
                    Text(display.localizedName)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(6)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 1) }
            .help(Text(verbatim: "\(display.localizedName): \(status.text)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(display.localizedName))
            .accessibilityValue(Text(verbatim: "\(asset?.displayName ?? String(localized: "No wallpaper chosen")), \(status.text)"))
    }
}
