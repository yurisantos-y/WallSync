import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportVideoUseCase {
    private let permissionStore: FilePermissionStore
    private let metadataLoader: AssetMetadataLoader
    private let posterFrameGenerator: PosterFrameGenerator
    private let posterCacheStore: PosterCacheStore
    private let videoAssetOptimizer: VideoAssetOptimizer

    init(
        permissionStore: FilePermissionStore,
        metadataLoader: AssetMetadataLoader,
        posterFrameGenerator: PosterFrameGenerator,
        posterCacheStore: PosterCacheStore,
        videoAssetOptimizer: VideoAssetOptimizer
    ) {
        self.permissionStore = permissionStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.posterCacheStore = posterCacheStore
        self.videoAssetOptimizer = videoAssetOptimizer
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
        let assetID = UUID()
        let maximumPixelSize = Self.maximumDisplayPixelSize()
        let optimizedPlayback = try? await videoAssetOptimizer.optimize(
            sourceURL: resolvedURL,
            metadata: metadata,
            assetID: assetID,
            maximumPixelSize: maximumPixelSize
        )
        let posterSourceURL = Self.optimizedPlaybackURL(for: optimizedPlayback) ?? resolvedURL
        let poster = try? await posterFrameGenerator.generatePoster(
            for: posterSourceURL,
            maxPixelSize: maximumPixelSize
        )
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
            optimizedPlayback: optimizedPlayback,
            hasAudio: metadata.hasAudio,
            posterImageRelativePath: posterPath,
            eligibility: metadata.playbackProfile,
            importedAt: .now
        )
    }

    private static func maximumDisplayPixelSize() -> CGSize {
        NSScreen.screens
            .map { screen in
                CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                )
            }
            .max { lhs, rhs in
                lhs.width * lhs.height < rhs.width * rhs.height
            } ?? CGSize(width: 1920, height: 1080)
    }

    private static func optimizedPlaybackURL(for optimizedPlayback: OptimizedPlaybackAsset?) -> URL? {
        guard let optimizedPlayback,
              let supportDirectory = try? FileManager.default.wallpaperApplicationSupportDirectory() else {
            return nil
        }

        let url = supportDirectory.appendingPathComponent(optimizedPlayback.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
