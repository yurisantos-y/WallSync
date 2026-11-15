import AppIntents
import Foundation

/// Gives App Intents access to the running app's coordinator.
@MainActor
enum AppIntentBridge {
    static weak var coordinator: AppCoordinator?

    /// The coordinator, once the saved library and assignments are loaded.
    /// An action that arrives while the app is still starting waits here
    /// instead of failing or acting on an empty state.
    static func ready() async throws -> AppCoordinator {
        guard let coordinator else { throw WallpaperIntentError.appNotReady }
        await coordinator.waitUntilRestored()
        return coordinator
    }
}

enum WallpaperIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case action(WallpaperActionError)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "WallSync is not ready yet. Try again in a moment."
        case .action(.wallpaperNotFound):
            return "That wallpaper is no longer in the WallSync library."
        case .action(.wallpaperNotPlayable):
            return "That wallpaper cannot be played on this Mac."
        case .action(.playlistNotFound):
            return "That playlist no longer exists in WallSync."
        case .action(.playlistEmpty):
            return "That playlist has no wallpapers."
        case .action(.displayNotConnected):
            return "That display is not connected."
        case .action(.noPlaylistInRotation):
            return "No playlist with more than one wallpaper is in rotation."
        }
    }
}

// MARK: - Wallpapers

struct WallpaperEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper"
    static let defaultQuery = WallpaperEntityQuery()

    let id: UUID
    let name: String
    /// The small library thumbnail, as data: Shortcuts cannot read files
    /// inside the app's container.
    let thumbnail: Data?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(String.LocalizationValue(name)), image: thumbnail.map { DisplayRepresentation.Image(data: $0) })
    }

    @MainActor
    static func make(_ asset: WallpaperAsset, coordinator: AppCoordinator) -> WallpaperEntity {
        let url = asset.thumbnailRelativePath.map(coordinator.storage.url(forRelativePath:))
        return WallpaperEntity(id: asset.id, name: asset.displayName, thumbnail: url.flatMap { try? Data(contentsOf: $0) })
    }
}

struct WallpaperEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [WallpaperEntity] {
        let coordinator = try await AppIntentBridge.ready()
        return coordinator.assets
            .filter { identifiers.contains($0.id) }
            .map { WallpaperEntity.make($0, coordinator: coordinator) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [WallpaperEntity] {
        let coordinator = try await AppIntentBridge.ready()
        return coordinator.assets
            .filter { $0.displayName.localizedCaseInsensitiveContains(string) }
            .map { WallpaperEntity.make($0, coordinator: coordinator) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WallpaperEntity] {
        let coordinator = try await AppIntentBridge.ready()
        return coordinator.assets.map { WallpaperEntity.make($0, coordinator: coordinator) }
    }
}

// MARK: - Playlists

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()

    let id: UUID
    let name: String
    let itemCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(String.LocalizationValue(name)),
            subtitle: "\(itemCount) wallpapers",
            image: DisplayRepresentation.Image(systemName: "rectangle.stack")
        )
    }

    static func make(_ playlist: WallpaperPlaylist) -> PlaylistEntity {
        PlaylistEntity(id: playlist.id, name: playlist.name, itemCount: Set(playlist.referencedAssetIDs).count)
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        try await AppIntentBridge.ready().playlists.filter { identifiers.contains($0.id) }.map(PlaylistEntity.make)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await AppIntentBridge.ready().playlists
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(PlaylistEntity.make)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await AppIntentBridge.ready().playlists.map(PlaylistEntity.make)
    }
}

// MARK: - Displays

struct DisplayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display"
    static let defaultQuery = DisplayEntityQuery()

    /// The display's hardware UUID, stable across reconnections.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(String.LocalizationValue(name)), image: DisplayRepresentation.Image(systemName: "display"))
    }
}

struct DisplayEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DisplayEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DisplayEntity] {
        try await AppIntentBridge.ready().displayManager.currentDisplays()
            .map { DisplayEntity(id: $0.displayUUID, name: $0.localizedName) }
    }
}
