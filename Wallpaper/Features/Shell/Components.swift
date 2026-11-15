import AppKit
import SwiftUI

// Small pieces shared by every page.

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// The picture of a wallpaper, filling whatever frame it is given. Loaded
/// asynchronously from the small thumbnail; nothing is decoded in `body`.
struct ThumbnailImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
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
}

/// A 16:9 thumbnail of a library wallpaper.
struct AssetThumbnail: View {
    @Environment(AppCoordinator.self) private var coordinator
    let asset: WallpaperAsset?
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { ThumbnailImage(url: asset.flatMap(coordinator.thumbnailURL(for:))) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }
}

// MARK: - What a display shows

/// The one choice behind "what does this show": nothing of its own, a fixed
/// wallpaper, or a playlist.
enum WallpaperSource: Hashable {
    case none
    case asset(UUID)
    case playlist(UUID)
}

/// One menu for wallpapers and playlists, so the two can never disagree.
struct WallpaperSourcePicker: View {
    @Environment(AppCoordinator.self) private var coordinator
    let title: Text
    /// The entry that stands for "nothing of its own".
    let noneLabel: Text
    @Binding var selection: WallpaperSource

    var body: some View {
        // A playlist with nothing in it cannot be shown.
        let playlists = coordinator.playlists.filter {
            !$0.referencedAssetIDs.isEmpty || selection == .playlist($0.id)
        }

        Picker(selection: $selection) {
            noneLabel.tag(WallpaperSource.none)

            if !coordinator.assets.isEmpty {
                Section("Wallpapers") {
                    ForEach(coordinator.assets) { asset in
                        Text(asset.displayName).tag(WallpaperSource.asset(asset.id))
                    }
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        Label(playlist.name, systemImage: playlist.kind.systemImage)
                            .tag(WallpaperSource.playlist(playlist.id))
                    }
                }
            }
        } label: {
            title
        }
    }
}

/// A menu of the library's wallpapers with a "None" entry.
struct AssetPicker: View {
    @Environment(AppCoordinator.self) private var coordinator
    let title: Text
    @Binding var selection: UUID?

    var body: some View {
        Picker(selection: $selection) {
            Text("None").tag(UUID?.none)
            Divider()
            ForEach(coordinator.assets) { asset in
                Text(asset.displayName).tag(UUID?.some(asset.id))
            }
        } label: {
            title
        }
    }
}

// MARK: - Status in plain words

/// What one display is doing, reduced to a colour, a word and a reason.
struct DisplayStatus: Equatable {
    var title: String
    /// Why it is not animating, when there is a reason.
    var reason: String?
    var color: Color

    var text: String {
        reason.map { "\(title) · \($0)" } ?? title
    }

    static func make(session: RenderSession?, hasWallpaper: Bool) -> DisplayStatus {
        guard let session else {
            return DisplayStatus(
                title: hasWallpaper ? String(localized: "Not running") : String(localized: "No wallpaper chosen"),
                reason: nil,
                color: .gray
            )
        }

        let reason = session.modeReason == .none ? nil : session.modeReason.localizedLabel
        switch session.playbackState {
        case .failed, .preparing:
            return DisplayStatus(title: session.playbackState.localizedLabel, reason: nil, color: session.playbackState.color)
        case .animating where session.energyMode == .animate:
            return DisplayStatus(title: session.playbackState.localizedLabel, reason: nil, color: .green)
        default:
            let label = session.energyMode == .animate
                ? session.playbackState.localizedLabel
                : session.energyMode.localizedLabel
            return DisplayStatus(title: label, reason: reason, color: session.energyMode == .poster ? .orange : .gray)
        }
    }
}

struct DisplayStatusLabel: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: status.color)
            Text(status.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension StatusSummary {
    var color: Color {
        switch self {
        case .animating: return .green
        case .pausedByUser: return .orange
        case .noWallpapers, .idle: return .gray
        }
    }
}

extension AppCoordinator {
    /// Names of the displays that show this wallpaper right now.
    func displayNames(showing assetID: UUID) -> [String] {
        runtimeState.activeDisplays
            .filter { resolution.content(forDisplayUUID: $0.displayUUID)?.assetID == assetID }
            .map(\.localizedName)
    }
}
