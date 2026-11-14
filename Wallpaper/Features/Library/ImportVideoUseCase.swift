import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportVideoUseCase {
    private let storage: StorageLocations
    private let permissionStore: FilePermissionStore
    private let metadataLoader: AssetMetadataLoader
    private let posterFrameGenerator: PosterFrameGenerator
    private let posterCacheStore: PosterCacheStore
    private let videoAssetOptimizer: VideoAssetOptimizer
    private let janitor: AssetStorageJanitor
    private let evaluator = PlaybackEligibilityEvaluator()

    init(
        storage: StorageLocations,
        permissionStore: FilePermissionStore,
        metadataLoader: AssetMetadataLoader,
        posterFrameGenerator: PosterFrameGenerator,
        posterCacheStore: PosterCacheStore,
        videoAssetOptimizer: VideoAssetOptimizer,
        janitor: AssetStorageJanitor
    ) {
        self.storage = storage
        self.permissionStore = permissionStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.posterCacheStore = posterCacheStore
        self.videoAssetOptimizer = videoAssetOptimizer
        self.janitor = janitor
    }

    func run() async throws -> WallpaperAsset? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose a video to use as wallpaper.")

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        return try await importVideo(at: selectedURL)
    }

    func importVideo(at selectedURL: URL) async throws -> WallpaperAsset {
        let bookmark = try await permissionStore.createBookmark(for: selectedURL)
        try await permissionStore.storeBookmark(bookmark)

        do {
            let resolvedURL = try await permissionStore.resolveBookmark(id: bookmark.id)
            let result: Result<WallpaperAsset, Error>
            do {
                result = .success(try await buildAsset(selectedURL: selectedURL, resolvedURL: resolvedURL, bookmarkID: bookmark.id))
            } catch {
                result = .failure(error)
            }
            await permissionStore.stopAccess(for: bookmark.id)
            return try result.get()
        } catch {
            // A failed import must not leave a bookmark behind.
            try? await permissionStore.removeBookmark(id: bookmark.id)
            throw error
        }
    }

    private func buildAsset(selectedURL: URL, resolvedURL: URL, bookmarkID: UUID) async throws -> WallpaperAsset {
        let displayName = selectedURL.deletingPathExtension().lastPathComponent
        let metadata: AssetInspectionResult
        do {
            metadata = try await metadataLoader.inspect(url: resolvedURL)
        } catch {
            throw ImportError.unreadable(name: displayName)
        }

        let assetID = UUID()
        let maximumPixelSize = Self.maximumDisplayPixelSize()
        let optimizedPlayback = try? await videoAssetOptimizer.optimize(
            sourceURL: resolvedURL,
            metadata: metadata,
            assetID: assetID,
            maximumPixelSize: maximumPixelSize
        )

        var asset = WallpaperAsset(
            id: assetID,
            displayName: displayName,
            originalBookmarkID: bookmarkID,
            originalPathHint: selectedURL.path,
            containerType: metadata.containerType,
            codecType: metadata.codecType,
            pixelSize: metadata.pixelSize,
            frameRate: metadata.frameRate,
            estimatedBitRate: metadata.estimatedBitRate,
            duration: metadata.duration,
            optimizedPlayback: optimizedPlayback,
            hasAudio: metadata.hasAudio,
            posterImageRelativePath: nil,
            eligibility: metadata.playbackProfile,
            importedAt: .now
        )

        // Nothing playable came out of the import: fail instead of leaving a
        // dead entry in the library.
        guard evaluator.effectiveProfile(for: asset).tier != .unsupported else {
            await janitor.removeFiles(ownedBy: asset)
            throw ImportError.cannotBePlayedOrConverted(name: displayName)
        }

        let posterSourceURL = storage.existingURL(forRelativePath: optimizedPlayback?.relativePath) ?? resolvedURL
        if let poster = try? await posterFrameGenerator.generatePosterBox(
            for: posterSourceURL,
            maxPixelSize: maximumPixelSize
        ) {
            asset.posterImageRelativePath = try? await posterCacheStore.savePoster(poster, for: assetID)
        }

        return asset
    }

    static func maximumDisplayPixelSize() -> CGSize {
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
}

enum ImportError: LocalizedError, Equatable {
    case unreadable(name: String)
    case cannotBePlayedOrConverted(name: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            return String(localized: "“\(name)” could not be read as a video.")
        case let .cannotBePlayedOrConverted(name):
            return String(localized: "“\(name)” cannot be played or converted on this Mac, so it was not imported.")
        }
    }
}
