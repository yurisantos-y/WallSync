import CoreGraphics
import Foundation

/// Production wiring of the session manager's dependencies.
@MainActor
final class LiveSessionEnvironment: SessionEnvironment {
    private let storage: StorageLocations
    private let posterCacheStore: PosterCacheStore

    init(storage: StorageLocations, posterCacheStore: PosterCacheStore) {
        self.storage = storage
        self.posterCacheStore = posterCacheStore
    }

    func makeSurface(for display: DisplayTarget) -> any WallpaperSurface {
        DesktopWallpaperWindowController(displayTarget: display)
    }

    func makeEngine() -> any SharedPlaybackEngine {
        AVPlayerPlaybackEngine()
    }

    func loadPoster(relativePath: String?) async -> CGImage? {
        await posterCacheStore.loadPoster(relativePath: relativePath)?.image
    }

    func optimizedPlaybackURL(for asset: WallpaperAsset) -> URL? {
        storage.existingURL(forRelativePath: asset.optimizedPlayback?.relativePath)
    }

    func captureWindowSnapshot() -> WindowListSnapshot {
        WindowListProvider.captureOnScreenWindows()
    }
}
