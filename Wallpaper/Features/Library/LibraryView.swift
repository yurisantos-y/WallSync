import SwiftUI

/// The library: a grid of wallpapers. Selecting one opens an inspector with
/// everything that can be done with it; double-clicking puts it on every
/// display.
struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var editedAsset: WallpaperAsset?
    @State private var pendingRemoval: WallpaperAsset?

    private var visibleAssets: [WallpaperAsset] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return coordinator.assets }
        return coordinator.assets.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var selectedAsset: WallpaperAsset? {
        coordinator.assets.first { $0.id == selection }
    }

    var body: some View {
        content
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.importVideos()
                    } label: {
                        Label("Import videos…", systemImage: "plus")
                    }
                    .help(Text("Opens a panel to choose one or more video files."))
                }
            }
            .searchable(text: $searchText, placement: .toolbar)
            .inspector(
                isPresented: Binding(
                    get: { selectedAsset != nil },
                    set: { if !$0 { selection = nil } }
                )
            ) {
                if let asset = selectedAsset {
                    AssetInspectorPane(
                        asset: asset,
                        onEdit: { editedAsset = asset },
                        onRemove: { pendingRemoval = asset }
                    )
                    .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
                }
            }
            .sheet(item: $editedAsset) { asset in
                AssetEditorView(asset: asset)
                    .environment(coordinator)
            }
            .confirmationDialog(
                Text("Remove “\(pendingRemoval?.displayName ?? "")” from the library?"),
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { asset in
                Button("Remove", role: .destructive) {
                    coordinator.removeAsset(asset)
                }
            } message: { _ in
                Text("The original video file is not deleted.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.assets.isEmpty {
            ContentUnavailableView {
                Label("No videos yet", systemImage: "photo.on.rectangle")
            } description: {
                Text("Import a video or drop one here to start your wallpaper library.")
            } actions: {
                Button("Import videos…") { coordinator.importVideos() }
                    .buttonStyle(.borderedProminent)
            }
        } else if visibleAssets.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            grid
        }
    }

    private var grid: some View {
        let activeIDs = Set(coordinator.resolution.displays.map(\.assetID))

        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 16)], spacing: 18) {
                ForEach(visibleAssets) { asset in
                    AssetTile(
                        asset: asset,
                        activity: coordinator.importActivity(for: asset),
                        isSelected: selection == asset.id,
                        isInUse: activeIDs.contains(asset.id)
                    )
                    .onTapGesture { selection = asset.id }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { coordinator.setGlobalAsset(asset.id) }
                    )
                    .contextMenu { tileMenu(for: asset) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(selection == asset.id ? .isSelected : [])
                    .accessibilityAction(named: Text("Use on all displays")) {
                        coordinator.setGlobalAsset(asset.id)
                    }
                }
            }
            .padding(20)
        }
        .background {
            // Clicking the empty area closes the inspector.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection = nil }
        }
    }

    @ViewBuilder
    private func tileMenu(for asset: WallpaperAsset) -> some View {
        Button("Use on all displays") {
            coordinator.setGlobalAsset(asset.id)
        }
        UseOnDisplayMenu(asset: asset)
        Divider()
        Button("Edit…") { editedAsset = asset }
            .disabled(asset.optimizationState != .ready)
        Button("Remove", role: .destructive) { pendingRemoval = asset }
    }
}

extension LibraryView {
    static let playbackRates: [Double] = [0.25, 0.5, 0.75, 1]
    static let dimmingSteps: [Double] = [0, 0.2, 0.4, 0.6, 0.8]

    static func rateLabel(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// "Use on ▸ <display>", offered only when there is more than one display.
private struct UseOnDisplayMenu: View {
    @Environment(AppCoordinator.self) private var coordinator
    let asset: WallpaperAsset

    var body: some View {
        let displays = coordinator.runtimeState.activeDisplays
        if displays.count > 1 {
            Menu("Use on one display") {
                ForEach(displays) { display in
                    Button(display.localizedName) {
                        coordinator.assignAsset(asset.id, to: display)
                    }
                }
            }
        }
    }
}

// MARK: - Tile

private struct AssetTile: View {
    let asset: WallpaperAsset
    let activity: ImportActivity?
    let isSelected: Bool
    let isInUse: Bool

    private var tier: PlaybackProfile.Tier {
        AssetInspector.effectiveProfile(for: asset).tier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnail(asset: asset, cornerRadius: 8)
                .overlay(alignment: .topLeading) {
                    if isInUse {
                        badge(systemImage: "display", text: Text("On screen"), color: .green)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if activity == nil, tier != .safe {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, tier == .unsupported ? Color.red : Color.orange)
                            .padding(6)
                            .help(Text(AssetInspector.statusText(for: asset)))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let activity {
                        progress(for: activity)
                    }
                }
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(activity == nil ? AssetInspector.shortSummary(for: asset) : AssetInspector.statusText(for: asset, activity: activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(asset.displayName))
        .accessibilityValue(Text(isInUse ? String(localized: "On screen") : AssetInspector.statusText(for: asset, activity: activity)))
    }

    private func badge(systemImage: String, text: Text, color: Color) -> some View {
        Label { text } icon: { Image(systemName: systemImage) }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .padding(6)
    }

    private func progress(for activity: ImportActivity) -> some View {
        Group {
            if activity.isQueued {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: activity.progress)
                    .progressViewStyle(.linear)
            }
        }
        .tint(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous))
        .accessibilityLabel(Text("Optimization progress"))
    }
}

// MARK: - Inspector

/// Everything about one wallpaper: where it is used, how it plays, and the
/// technical details for those who want them.
private struct AssetInspectorPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    let asset: WallpaperAsset
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let activity = coordinator.importActivity(for: asset)
        let profile = AssetInspector.effectiveProfile(for: asset)
        let shownOn = coordinator.displayNames(showing: asset.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AssetThumbnail(asset: asset, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.displayName)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    statusLine(activity: activity, profile: profile)
                }

                if let activity {
                    activityRow(activity)
                }

                ForEach(notices(activity: activity, profile: profile), id: \.text) { notice in
                    Label {
                        Text(notice.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: notice.systemImage)
                            .foregroundStyle(notice.color)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        coordinator.setGlobalAsset(asset.id)
                    } label: {
                        Text("Use on all displays")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(profile.tier == .unsupported && activity == nil)

                    UseOnDisplayMenu(asset: asset)

                    if !shownOn.isEmpty {
                        Label {
                            Text("Showing on \(shownOn.formatted(.list(type: .and)))")
                        } icon: {
                            Image(systemName: "display")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()
                playbackControls

                Divider()
                editControls(activity: activity)

                Divider()
                DisclosureGroup("Details") {
                    details
                        .padding(.top, 6)
                }
                .font(.callout)

                Button("Remove from library…", role: .destructive, action: onRemove)
                    .accessibilityLabel(Text("Remove \(asset.displayName)"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusLine(activity: ImportActivity?, profile: PlaybackProfile) -> some View {
        let color: Color
        if activity != nil || (asset.optimizationState == .pending && asset.optimizedPlayback == nil) {
            color = .blue
        } else {
            switch profile.tier {
            case .safe: color = .green
            case .warning: color = .orange
            case .unsupported: color = .red
            }
        }
        return HStack(spacing: 6) {
            StatusDot(color: color)
            Text(AssetInspector.statusText(for: asset, activity: activity))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func activityRow(_ activity: ImportActivity) -> some View {
        HStack(spacing: 10) {
            if activity.isQueued {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: activity.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text("Optimization progress"))
            }
            Button("Cancel") { coordinator.cancelImport(of: asset) }
                .controlSize(.small)
                .accessibilityLabel(Text("Cancel optimization of \(asset.displayName)"))
        }
    }

    private struct Notice {
        var systemImage: String
        var color: Color
        var text: String
    }

    /// Things the user should know about, in plain words. Empty when all is well.
    private func notices(activity: ImportActivity?, profile: PlaybackProfile) -> [Notice] {
        var notices: [Notice] = []
        if activity == nil, profile.tier != .safe, !profile.reasonCodes.isEmpty {
            let reasons = profile.reasonCodes.map(AssetInspector.reasonLabel(for:)).joined(separator: ", ")
            notices.append(
                Notice(
                    systemImage: "exclamationmark.triangle.fill",
                    color: profile.tier == .unsupported ? .red : .orange,
                    text: String(localized: "Notes: \(reasons)")
                )
            )
        }
        if asset.originalUnavailable {
            notices.append(
                Notice(
                    systemImage: "questionmark.folder",
                    color: .orange,
                    text: String(localized: "A sharper copy could not be made because the original file cannot be reached. The current copy is kept.")
                )
            )
        }
        if activity == nil, !asset.editRecipe.isEmpty, OptimizationPlanner.isStale(asset: asset) {
            notices.append(
                Notice(systemImage: "clock.arrow.circlepath", color: .orange, text: String(localized: "Edits not applied"))
            )
        }
        return notices
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed")
                    .font(.callout.weight(.medium))
                Picker(
                    "Speed",
                    selection: Binding(
                        get: { asset.effectivePlaybackRate },
                        set: { coordinator.updatePlaybackRate($0, for: asset.id) }
                    )
                ) {
                    ForEach(LibraryView.playbackRates, id: \.self) { rate in
                        Text(verbatim: LibraryView.rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(Text("Speed of \(asset.displayName)"))
                Text("Slower playback is calmer and uses less energy: fewer frames are decoded each second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(
                "Dimming",
                selection: Binding<Double?>(
                    get: { asset.dimmingOverride.map { ($0 * 10).rounded() / 10 } },
                    set: { coordinator.updateDimmingOverride($0, for: asset.id) }
                )
            ) {
                Text("Same as in Settings").tag(Optional<Double>.none)
                Divider()
                ForEach(LibraryView.dimmingSteps, id: \.self) { amount in
                    Text(amount.formatted(.percent.precision(.fractionLength(0)))).tag(Optional(amount))
                }
            }
            .font(.callout.weight(.medium))
            .accessibilityLabel(Text("Dimming of \(asset.displayName)"))
        }
    }

    private func editControls(activity: ImportActivity?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onEdit) {
                Label("Edit loop or remove a logo…", systemImage: "scissors")
            }
            .disabled(asset.optimizationState != .ready)
            .accessibilityLabel(Text("Edit \(asset.displayName)"))

            if let summary = AssetInspector.editSummary(for: asset) {
                Text("Edited: \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            detail(Text("Original"), AssetInspector.technicalSummary(for: asset))
            if let rendition = AssetInspector.renditionSummary(for: asset) {
                detail(Text("Playback"), rendition)
            }
            if let strategies = asset.optimizedPlayback?.watermarkStrategies, !strategies.isEmpty {
                let labels = Set(strategies.compactMap(WatermarkStrategy.init(rawValue:)))
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.localizedLabel)
                detail(Text("Logo removal"), labels.joined(separator: ", "))
            }
            if asset.hasAudio {
                detail(Text("Sound"), String(localized: "Plays without sound"))
            }
            detail(Text("Imported"), asset.importedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: Text, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
