import Foundation

/// What a Shortcuts action or a Focus filter asks the app to do.
enum WallpaperActionRequest: Equatable, Sendable {
    case setWallpaper(assetID: UUID, displayUUID: String?)
    case activatePlaylist(playlistID: UUID, displayUUID: String?)
    case nextWallpaper
}

/// Why a request cannot be carried out; each case has a clear, localized
/// message for the Shortcuts app.
enum WallpaperActionError: Error, Equatable, Sendable {
    case wallpaperNotFound
    case wallpaperNotPlayable
    case playlistNotFound
    case playlistEmpty
    case displayNotConnected
    case noPlaylistInRotation
}

/// Checks a request against the current library and displays before
/// anything is changed, so an action never acts on something that is gone.
enum IntentRequestValidator {
    static func validate(
        _ request: WallpaperActionRequest,
        assets: [WallpaperAsset],
        playlists: [WallpaperPlaylist],
        displays: [DisplayTarget],
        advanceablePlaylistIDs: Set<UUID>
    ) throws {
        func requireDisplay(_ displayUUID: String?) throws {
            guard let displayUUID else { return }
            guard displays.contains(where: { $0.displayUUID == displayUUID }) else {
                throw WallpaperActionError.displayNotConnected
            }
        }

        switch request {
        case let .setWallpaper(assetID, displayUUID):
            guard let asset = assets.first(where: { $0.id == assetID }) else {
                throw WallpaperActionError.wallpaperNotFound
            }
            guard PlaybackEligibilityEvaluator().effectiveProfile(for: asset).tier != .unsupported else {
                throw WallpaperActionError.wallpaperNotPlayable
            }
            try requireDisplay(displayUUID)

        case let .activatePlaylist(playlistID, displayUUID):
            guard let playlist = playlists.first(where: { $0.id == playlistID }) else {
                throw WallpaperActionError.playlistNotFound
            }
            let existing = Set(assets.map(\.id))
            guard playlist.referencedAssetIDs.contains(where: existing.contains) else {
                throw WallpaperActionError.playlistEmpty
            }
            try requireDisplay(displayUUID)

        case .nextWallpaper:
            guard !advanceablePlaylistIDs.isEmpty else {
                throw WallpaperActionError.noPlaylistInRotation
            }
        }
    }
}

/// What a Focus filter is set to do while its Focus is on.
enum FocusFilterBehavior: String, Sendable, CaseIterable {
    case noChange
    case pause
    case wallpaper
    case playlist

    /// The temporary override for the resolver. A filter that names nothing
    /// (or is left at "no change", which is also what the system sends when
    /// the Focus ends) clears the override.
    func override(wallpaperID: UUID?, playlistID: UUID?) -> FocusOverride? {
        switch self {
        case .noChange: return nil
        case .pause: return .pause
        case .wallpaper: return wallpaperID.map(FocusOverride.asset)
        case .playlist: return playlistID.map(FocusOverride.playlist)
        }
    }
}
