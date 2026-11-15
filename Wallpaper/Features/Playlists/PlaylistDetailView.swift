import SwiftUI

/// The page of one playlist: whether it is in use, the rule that picks the
/// wallpaper, and the wallpapers themselves.
struct PlaylistDetailView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let playlist: WallpaperPlaylist
    @State private var confirmsDeletion = false

    private static let intervals: [TimeInterval] = [60, 300, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400]

    private func update(_ change: (inout WallpaperPlaylist) -> Void) {
        var copy = playlist
        change(&copy)
        coordinator.updatePlaylist(copy)
    }

    private func asset(_ id: UUID?) -> WallpaperAsset? {
        coordinator.assets.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    "Name",
                    text: Binding(get: { playlist.name }, set: { name in update { $0.name = name } })
                )
                .accessibilityLabel(Text("Playlist name"))

                usageRow
            }

            Section {
                Picker(
                    "Changes",
                    selection: Binding(get: { playlist.kind }, set: { kind in update { $0.kind = kind } })
                ) {
                    Text("After a while").tag(WallpaperPlaylist.Kind.interval)
                    Text("By time of day").tag(WallpaperPlaylist.Kind.timeOfDay)
                    Text("Light and dark").tag(WallpaperPlaylist.Kind.appearance)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("How \(playlist.name) advances"))

                switch playlist.kind {
                case .interval: intervalOptions
                case .timeOfDay, .appearance: EmptyView()
                }
            } footer: {
                footnote(kindDescription)
            }

            switch playlist.kind {
            case .interval: intervalItems
            case .timeOfDay: timeOfDayItems
            case .appearance: appearanceItems
            }
        }
        .formStyle(.grouped)
        .navigationTitle(playlist.name.isEmpty ? String(localized: "Untitled playlist") : playlist.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help(Text("Delete the playlist \(playlist.name)"))
            }
        }
        .confirmationDialog(
            Text("Delete the playlist \(playlist.name)"),
            isPresented: $confirmsDeletion
        ) {
            Button("Delete", role: .destructive) { coordinator.deletePlaylist(playlist.id) }
        } message: {
            Text("The wallpapers stay in your library.")
        }
    }

    private func footnote(_ text: Text) -> some View {
        text
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindDescription: Text {
        switch playlist.kind {
        case .interval: return Text("Shows the next wallpaper after the chosen time, only while the desktop is visible.")
        case .timeOfDay: return Text("Each wallpaper is shown from its time until the next one begins.")
        case .appearance: return Text("Follows the light and dark appearance of macOS.")
        }
    }

    // MARK: - Usage

    private var usageRow: some View {
        let isAssigned = coordinator.isPlaylistAssigned(playlist.id)
        let displays = coordinator.runtimeState.activeDisplays

        return HStack(spacing: 10) {
            if isAssigned {
                StatusDot(color: .green)
                Text("In rotation")
                Spacer()
                if playlist.kind == .interval {
                    Button("Next wallpaper") { coordinator.advancePlaylists() }
                        .disabled(!coordinator.canAdvanceNow(playlist))
                }
                Button("Stop") { coordinator.deactivatePlaylist(playlist.id) }
                    .help(Text("Goes back to the fixed wallpaper."))
            } else {
                Text("Not in use")
                    .foregroundStyle(.secondary)
                Spacer()
                if displays.count > 1 {
                    Menu("Use on one display") {
                        ForEach(displays) { display in
                            Button(display.localizedName) {
                                coordinator.activatePlaylist(playlist.id, on: display)
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(playlist.referencedAssetIDs.isEmpty)
                }
                Button("Use on all displays") { coordinator.activatePlaylist(playlist.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(playlist.referencedAssetIDs.isEmpty)
                    .help(playlist.referencedAssetIDs.isEmpty ? Text("Add wallpapers to this playlist.") : Text(verbatim: ""))
            }
        }
    }

    // MARK: - Interval

    @ViewBuilder
    private var intervalOptions: some View {
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

        Toggle(
            "Shuffle",
            isOn: Binding(get: { playlist.isShuffled }, set: { value in update { $0.isShuffled = value } })
        )
    }

    private var intervalItems: some View {
        Section {
            if playlist.assetIDs.isEmpty {
                Text("Add wallpapers to this playlist.")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(playlist.assetIDs.enumerated()), id: \.offset) { index, assetID in
                let asset = asset(assetID)
                HStack(spacing: 10) {
                    AssetThumbnail(asset: asset, cornerRadius: 4)
                        .frame(width: 56)
                    itemTitle(asset)
                    Spacer()

                    Group {
                        Button {
                            update { $0.assetIDs.swapAt(index, index - 1) }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(Text("Move up"))

                        Button {
                            update { $0.assetIDs.swapAt(index, index + 1) }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == playlist.assetIDs.count - 1)
                        .accessibilityLabel(Text("Move down"))

                        Button {
                            update { $0.assetIDs.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(Text("Remove \(asset?.displayName ?? "") from the playlist"))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Menu {
                ForEach(coordinator.assets) { asset in
                    Button(asset.displayName) {
                        update { $0.assetIDs.append(asset.id) }
                    }
                }
            } label: {
                Label("Add wallpaper", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(coordinator.assets.isEmpty)
        } header: {
            Text("Wallpapers")
        } footer: {
            if hasPendingItems {
                footnote(Text("Wallpapers still being optimized are skipped until they are ready."))
            }
        }
    }

    /// Name of an item, with a note when it cannot be shown yet.
    private func itemTitle(_ asset: WallpaperAsset?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(asset?.displayName ?? String(localized: "Removed wallpaper"))
                .lineLimit(1)
                .truncationMode(.middle)
            if let asset, !asset.isReadyForRotation {
                Text(AssetInspector.statusText(for: asset, activity: coordinator.importActivity(for: asset)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasPendingItems: Bool {
        playlist.referencedAssetIDs.contains { id in
            asset(id).map { !$0.isReadyForRotation } ?? false
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

    private var timeOfDayItems: some View {
        Section {
            ForEach(playlist.slots.sorted { $0.startMinute < $1.startMinute }) { slot in
                HStack(spacing: 10) {
                    AssetThumbnail(asset: asset(slot.assetID), cornerRadius: 4)
                        .frame(width: 56)

                    DatePicker(
                        "Starts at",
                        selection: Binding(
                            get: { Self.date(forMinute: slot.startMinute) },
                            set: { date in
                                let minute = Self.minute(of: date)
                                updateSlot(slot.id) { $0.startMinute = minute }
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Starts at"))

                    AssetPicker(
                        title: Text("Wallpaper"),
                        selection: Binding(
                            get: { slot.assetID },
                            set: { assetID in updateSlot(slot.id) { $0.assetID = assetID } }
                        )
                    )
                    .labelsHidden()
                    .fixedSize()

                    Spacer()

                    Button {
                        update { playlist in playlist.slots.removeAll { $0.id == slot.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove this time"))
                }
            }

            Button {
                update { playlist in
                    // Morning, afternoon, night; then an hour after the last.
                    let defaults = [6 * 60, 12 * 60, 19 * 60]
                    let used = Set(playlist.slots.map(\.startMinute))
                    let next = defaults.first { !used.contains($0) }
                        ?? min((playlist.slots.map(\.startMinute).max() ?? 0) + 60, 23 * 60 + 59)
                    playlist.slots.append(.init(startMinute: next, assetID: nil))
                }
            } label: {
                Label("Add time", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Times")
        } footer: {
            if hasPendingItems {
                footnote(Text("Wallpapers still being optimized are skipped until they are ready."))
            }
        }
    }

    private func updateSlot(_ id: UUID, _ change: (inout WallpaperPlaylist.TimeSlot) -> Void) {
        update { playlist in
            if let index = playlist.slots.firstIndex(where: { $0.id == id }) {
                change(&playlist.slots[index])
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

    private var appearanceItems: some View {
        Section {
            appearanceRow(Text("Light appearance"), systemImage: "sun.max", isLight: true)
            appearanceRow(Text("Dark appearance"), systemImage: "moon", isLight: false)
        } header: {
            Text("Wallpapers")
        } footer: {
            if hasPendingItems {
                footnote(Text("Wallpapers still being optimized are skipped until they are ready."))
            }
        }
    }

    private func appearanceRow(_ title: Text, systemImage: String, isLight: Bool) -> some View {
        let assetID = isLight ? playlist.lightAssetID : playlist.darkAssetID
        return HStack(spacing: 10) {
            AssetThumbnail(asset: asset(assetID), cornerRadius: 4)
                .frame(width: 56)
            AssetPicker(
                title: Text(Image(systemName: systemImage)) + Text(verbatim: "  ") + title,
                selection: Binding(
                    get: { assetID },
                    set: { value in
                        update {
                            if isLight { $0.lightAssetID = value } else { $0.darkAssetID = value }
                        }
                    }
                )
            )
        }
    }
}
