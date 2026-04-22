import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportVideoUseCase {
    private let permissionStore: FilePermissionStore
    private let metadataLoader: AssetMetadataLoader
    private let posterFrameGenerator: PosterFrameGenerator
    private let posterCacheStore: PosterCacheStore

    init(
        permissionStore: FilePermissionStore,
        metadataLoader: AssetMetadataLoader,
        posterFrameGenerator: PosterFrameGenerator,
        posterCacheStore: PosterCacheStore
    ) {
        self.permissionStore = permissionStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.posterCacheStore = posterCacheStore
    }

    func run() async throws -> WallpaperAsset? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Importar"
        panel.message = "Selecione um video MP4 ou MOV para usar como wallpaper."

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let bookmark = try await permissionStore.createBookmark(for: selectedURL)
        try await permissionStore.storeBookmark(bookmark)
        let resolvedURL = try await permissionStore.resolveBookmark(id: bookmark.id)
        defer {
            Task {
                await permissionStore.stopAccess(for: bookmark.id)
            }
        }

        let metadata = try await metadataLoader.inspect(url: resolvedURL)
        let poster = try? await posterFrameGenerator.generatePoster(for: resolvedURL)
        let assetID = UUID()
        let posterPath: String?
        if let poster {
            posterPath = try await posterCacheStore.savePoster(poster, for: assetID)
        } else {
            posterPath = nil
        }

        return WallpaperAsset(
            id: assetID,
            displayName: selectedURL.deletingPathExtension().lastPathComponent,
            originalBookmarkID: bookmark.id,
            originalPathHint: selectedURL.path,
            containerType: metadata.containerType,
            codecType: metadata.codecType,
            pixelSize: metadata.pixelSize,
            frameRate: metadata.frameRate,
            estimatedBitRate: metadata.estimatedBitRate,
            duration: metadata.duration,
            hasAudio: metadata.hasAudio,
            posterImageRelativePath: posterPath,
            eligibility: metadata.playbackProfile,
            importedAt: .now
        )
    }
}
