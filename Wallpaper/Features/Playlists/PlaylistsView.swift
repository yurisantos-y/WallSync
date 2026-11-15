import SwiftUI

struct PlaylistsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Playlists"),
                subtitle: String(localized: "Sets of wallpapers that change after a while, by time of day, or with the light and dark appearance.")
            ) {
                Button("New playlist") {
                    coordinator.createPlaylist()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if coordinator.playlists.isEmpty {
                WallpaperGlassCard {
                    ContentUnavailableView(
                        "No playlists yet",
                        systemImage: "rectangle.stack",
                        description: Text("Create a playlist, add wallpapers from your library and choose how it advances.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.playlists) { playlist in
                        PlaylistCard(playlist: playlist)
                    }
                }
            }
        }
    }
}

private struct PlaylistCard: View {
    @Environment(AppCoordinator.self) private var coordinator
    let playlist: WallpaperPlaylist

    private static let intervals: [TimeInterval] = [60, 300, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400]

    private func update(_ change: (inout WallpaperPlaylist) -> Void) {
        var copy = playlist
        change(&copy)
        coordinator.updatePlaylist(copy)
    }

    private var isActive: Bool {
        coordinator.resolution.activePlaylistIDs.contains(playlist.id)
    }

    var body: some View {
        WallpaperGlassCard(padding: 18, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    TextField(
                        "Name",
                        text: Binding(get: { playlist.name }, set: { name in update { $0.name = name } })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 320)
                    .accessibilityLabel(Text("Playlist name"))

                    Spacer()

                    if isActive {
                        WallpaperStatusPill(label: String(localized: "In rotation"), color: .green)
                    }
                }

                Picker(
                    "Advance",
                    selection: Binding(get: { playlist.kind }, set: { kind in update { $0.kind = kind } })
                ) {
                    Text("After a while").tag(WallpaperPlaylist.Kind.interval)
                    Text("By time of day").tag(WallpaperPlaylist.Kind.timeOfDay)
                    Text("Light and dark").tag(WallpaperPlaylist.Kind.appearance)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("How \(playlist.name) advances"))

                switch playlist.kind {
                case .interval: intervalEditor
                case .timeOfDay: timeOfDayEditor
                case .appearance: appearanceEditor
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Use on all displays") {
                        coordinator.activatePlaylist(playlist.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playlist.referencedAssetIDs.isEmpty)

                    Button("Delete", role: .destructive) {
                        coordinator.deletePlaylist(playlist.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text("Delete the playlist \(playlist.name)"))

                    Spacer()

                    if hasPendingItems {
                        Text("Wallpapers still being optimized are skipped until they are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var hasPendingItems: Bool {
        playlist.referencedAssetIDs.contains { id in
            coordinator.assets.first { $0.id == id }.map { !$0.isReadyForRotation } ?? false
        }
    }

    private func name(of assetID: UUID) -> String {
        coordinator.assets.first { $0.id == assetID }?.displayName ?? String(localized: "Removed wallpaper")
    }

    // MARK: - Interval

    private var intervalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker(
                    "Change every",
                    selection: Binding(
                        get: { playlist.intervalSeconds },
                        set: { value in update { $0.intervalSeconds = value } }
                    )
                ) {
                    ForEach(intervalChoices, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Toggle(
                    "Shuffle",
                    isOn: Binding(get: { playlist.isShuffled }, set: { value in update { $0.isShuffled = value } })
                )
            }

            if playlist.assetIDs.isEmpty {
                Text("Add wallpapers to this playlist.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Rows can be dragged to reorder.
                List {
                    ForEach(Array(playlist.assetIDs.enumerated()), id: \.offset) { index, assetID in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(name(of: assetID))
                            Spacer()
                            Button {
                                update { $0.assetIDs.remove(at: index) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove \(name(of: assetID)) from the playlist"))
                        }
                    }
                    .onMove { source, destination in
                        update { $0.assetIDs.move(fromOffsets: source, toOffset: destination) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(playlist.assetIDs.count) * 30 + 8, 220))
            }

            Menu("Add wallpaper") {
                ForEach(coordinator.assets) { asset in
                    Button(asset.displayName) {
                        update { $0.assetIDs.append(asset.id) }
                    }
                }
            }
            .fixedSize()
            .disabled(coordinator.assets.isEmpty)
        }
    }

    private var intervalChoices: [TimeInterval] {
        Self.intervals.contains(playlist.intervalSeconds)
            ? Self.intervals
            : (Self.intervals + [playlist.intervalSeconds]).sorted()
    }

    static func intervalLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? "\(Int(seconds / 60)) min"
    }

    // MARK: - Time of day

    private var timeOfDayEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(playlist.slots.sorted { $0.startMinute < $1.startMinute }) { slot in
                HStack(spacing: 12) {
                    DatePicker(
                        "Starts at",
                        selection: Binding(
                            get: { Self.date(forMinute: slot.startMinute) },
                            set: { date in
                                let minute = Self.minute(of: date)
                                update { playlist in
                                    if let index = playlist.slots.firstIndex(where: { $0.id == slot.id }) {
                                        playlist.slots[index].startMinute = minute
                                    }
                                }
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Starts at"))

                    assetPicker(
                        title: String(localized: "Wallpaper"),
                        selection: slot.assetID
                    ) { assetID in
                        update { playlist in
                            if let index = playlist.slots.firstIndex(where: { $0.id == slot.id }) {
                                playlist.slots[index].assetID = assetID
                            }
                        }
                    }

                    Button {
                        update { playlist in playlist.slots.removeAll { $0.id == slot.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove this time"))
                }
            }

            Button("Add time") {
                update { playlist in
                    // Morning, afternoon, night; then an hour after the last.
                    let defaults = [6 * 60, 12 * 60, 19 * 60]
                    let used = Set(playlist.slots.map(\.startMinute))
                    let next = defaults.first { !used.contains($0) }
                        ?? min((playlist.slots.map(\.startMinute).max() ?? 0) + 60, 23 * 60 + 59)
                    playlist.slots.append(.init(startMinute: next, assetID: nil))
                }
            }
        }
    }

    private static func date(forMinute minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    private static func minute(of date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: - Appearance

    private var appearanceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            assetPicker(title: String(localized: "Light appearance"), selection: playlist.lightAssetID) { assetID in
                update { $0.lightAssetID = assetID }
            }
            assetPicker(title: String(localized: "Dark appearance"), selection: playlist.darkAssetID) { assetID in
                update { $0.darkAssetID = assetID }
            }
        }
    }

    private func assetPicker(title: String, selection: UUID?, onChange: @escaping (UUID?) -> Void) -> some View {
        AssetPicker(title: title, selection: selection, assets: coordinator.assets, onChange: onChange)
    }
}

/// A menu of the library's wallpapers with a "None" entry.
private struct AssetPicker: View {
    let title: String
    let selection: UUID?
    let assets: [WallpaperAsset]
    let onChange: (UUID?) -> Void

    var body: some View {
        Menu {
            Button(String(localized: "None")) { onChange(nil) }
            Divider()
            ForEach(assets) { asset in
                Button(asset.displayName) { onChange(asset.id) }
            }
        } label: {
            Text(verbatim: "\(title): \(assets.first { $0.id == selection }?.displayName ?? String(localized: "None"))")
        }
        .fixedSize()
    }
}
