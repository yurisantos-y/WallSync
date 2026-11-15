import AppKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var editedAsset: WallpaperAsset?

    var body: some View {
        page
            .sheet(item: $editedAsset) { asset in
                AssetEditorView(asset: asset)
                    .environment(coordinator)
            }
    }

    private var page: some View {
        WallpaperPageScrollView {
            WallpaperPageHeader(
                String(localized: "Library"),
                subtitle: String(localized: "Import videos, or drag them into this window, and choose the wallpaper for all displays.")
            ) {
                Button("Import videos…") {
                    coordinator.importVideos()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint(Text("Opens a panel to choose one or more video files."))
            }

            if coordinator.assets.isEmpty {
                WallpaperGlassCard {
                    ContentUnavailableView(
                        "No videos yet",
                        systemImage: "film.stack",
                        description: Text("Import a video or drop one here to start your wallpaper library.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(coordinator.assets) { asset in
                        assetCard(for: asset)
                    }
                }
            }
        }
    }

    private func statusColor(for asset: WallpaperAsset, activity: ImportActivity?) -> Color {
        if activity != nil || (asset.optimizationState == .pending && asset.optimizedPlayback == nil) {
            return .blue
        }

        switch AssetInspector.effectiveProfile(for: asset).tier {
        case .safe:
            return .green
        case .warning:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private func assetCard(for asset: WallpaperAsset) -> some View {
        let activity = coordinator.importActivity(for: asset)
        let profile = AssetInspector.effectiveProfile(for: asset)

        return WallpaperGlassCard(padding: 18, cornerRadius: 26) {
            HStack(alignment: .top, spacing: 18) {
                AssetPosterThumbnailView(url: coordinator.thumbnailURL(for: asset))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(asset.displayName)
                                .font(.title3.weight(.semibold))
                            Text(AssetInspector.technicalSummary(for: asset))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let rendition = AssetInspector.renditionSummary(for: asset) {
                                Text(rendition)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 12)

                        WallpaperStatusPill(
                            label: AssetInspector.statusText(for: asset, activity: activity),
                            color: statusColor(for: asset, activity: activity)
                        )
                    }

                    if let activity {
                        HStack(spacing: 12) {
                            if activity.isQueued {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            } else {
                                ProgressView(value: activity.progress)
                                    .progressViewStyle(.linear)
                                    .accessibilityLabel(Text("Optimization progress"))
                            }

                            Button("Cancel") {
                                coordinator.cancelImport(of: asset)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(Text("Cancel optimization of \(asset.displayName)"))
                        }
                    }

                    if let strategies = asset.optimizedPlayback?.watermarkStrategies, !strategies.isEmpty, activity == nil {
                        let labels = Set(strategies.compactMap(WatermarkStrategy.init(rawValue:)))
                            .sorted { $0.rawValue < $1.rawValue }
                            .map(\.localizedLabel)
                        Text("Logo removal: \(labels.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !profile.reasonCodes.isEmpty {
                        Text("Notes: \(profile.reasonCodes.map(AssetInspector.reasonLabel(for:)).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        if coordinator.globalAssetID() == asset.id {
                            WallpaperStatusPill(label: String(localized: "On all displays"), color: .blue)
                        }

                        if asset.sourceIsHDR || asset.optimizedPlayback?.isHDR == true {
                            WallpaperStatusPill(label: "HDR", color: .purple)
                        }

                        if asset.hasAudio {
                            WallpaperStatusPill(label: String(localized: "Plays without sound"), color: .gray)
                        }

                        if !asset.editRecipe.isEmpty {
                            WallpaperStatusPill(
                                label: activity == nil && OptimizationPlanner.isStale(asset: asset)
                                    ? String(localized: "Edits not applied")
                                    : String(localized: "Edited"),
                                color: activity == nil && OptimizationPlanner.isStale(asset: asset) ? .orange : .blue
                            )
                        }

                        if asset.originalUnavailable {
                            WallpaperStatusPill(label: String(localized: "Original file unavailable"), color: .orange)
                                .help(Text("A sharper copy could not be made because the original file cannot be reached. The current copy is kept."))
                        }
                    }

                    assetAdjustments(for: asset)

                    HStack(spacing: 10) {
                        Button("Use on all displays") {
                            coordinator.setGlobalAsset(asset.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(profile.tier == .unsupported && activity == nil)

                        Button("Edit…") {
                            editedAsset = asset
                        }
                        .buttonStyle(.bordered)
                        .disabled(asset.optimizationState != .ready)
                        .accessibilityLabel(Text("Edit \(asset.displayName)"))

                        Button("Remove", role: .destructive) {
                            coordinator.removeAsset(asset)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Text("Remove \(asset.displayName)"))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension LibraryView {
    static let playbackRates: [Double] = [0.25, 0.5, 0.75, 1]
    static let dimmingSteps: [Double] = [0, 0.2, 0.4, 0.6, 0.8]

    static func rateLabel(_ rate: Double) -> String {
        rate == 1
            ? String(localized: "Normal speed")
            : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// Per-wallpaper settings that take effect without a new rendition.
    @ViewBuilder
    fileprivate func assetAdjustments(for asset: WallpaperAsset) -> some View {
        HStack(spacing: 14) {
            Picker(
                "Speed",
                selection: Binding(
                    get: { asset.effectivePlaybackRate },
                    set: { coordinator.updatePlaybackRate($0, for: asset.id) }
                )
            ) {
                ForEach(Self.playbackRates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(Text("Slower playback is calmer and uses less energy: fewer frames are decoded each second."))
            .accessibilityLabel(Text("Speed of \(asset.displayName)"))

            Picker(
                "Dimming",
                selection: Binding<Double?>(
                    get: { asset.dimmingOverride.map { ($0 * 10).rounded() / 10 } },
                    set: { coordinator.updateDimmingOverride($0, for: asset.id) }
                )
            ) {
                Text("Same as in Settings").tag(Optional<Double>.none)
                ForEach(Self.dimmingSteps, id: \.self) { amount in
                    Text(amount.formatted(.percent.precision(.fractionLength(0)))).tag(Optional(amount))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(Text("Dimming of \(asset.displayName)"))
        }
    }
}

/// Loads the small thumbnail asynchronously; nothing is decoded in `body`.
private struct AssetPosterThumbnailView: View {
    let url: URL?
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: placeholderGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                )
            }
        }
        .frame(width: 220, height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = ThumbnailCache.shared.cachedImage(for: url)
            if image == nil {
                image = await ThumbnailCache.shared.image(for: url)
            }
        }
    }

    private var placeholderGradient: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.18, green: 0.24, blue: 0.33),
                Color(red: 0.22, green: 0.19, blue: 0.17)
            ]
        }

        return [
            Color(red: 0.87, green: 0.90, blue: 0.95),
            Color(red: 0.96, green: 0.89, blue: 0.78)
        ]
    }
}
