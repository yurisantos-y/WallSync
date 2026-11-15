import AppKit
import Foundation
import UniformTypeIdentifiers

/// Progress of a background optimization, shown in the library.
struct ImportActivity: Equatable, Sendable {
    var progress: Double
    /// Waiting for an earlier optimization to finish.
    var isQueued: Bool
    /// Producing a better rendition of an asset that is already usable.
    var isReoptimization: Bool
}

/// The two steps of bringing a video into the library:
///
/// 1. `register` — fast: permission bookmark, metadata, poster. The asset can
///    be shown in the library right after it.
/// 2. `optimize` — slow: produce the playback rendition. Runs in the
///    background, reports progress and can be cancelled.
@MainActor
final class AssetImportPipeline {
    private let storage: StorageLocations
    private let permissionStore: FilePermissionStore
    private let metadataLoader: AssetMetadataLoader
    private let posterFrameGenerator: PosterFrameGenerator
    private let posterCacheStore: PosterCacheStore
    private let videoAssetOptimizer: VideoAssetOptimizer

    init(
        storage: StorageLocations,
        permissionStore: FilePermissionStore,
        metadataLoader: AssetMetadataLoader,
        posterFrameGenerator: PosterFrameGenerator,
        posterCacheStore: PosterCacheStore,
        videoAssetOptimizer: VideoAssetOptimizer
    ) {
        self.storage = storage
        self.permissionStore = permissionStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.posterCacheStore = posterCacheStore
        self.videoAssetOptimizer = videoAssetOptimizer
    }

    static let importableContentTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]

    /// Shows the open panel; several files can be chosen at once.
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = importableContentTypes
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose one or more videos to use as wallpaper.")

        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func isImportable(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return importableContentTypes.contains { type.conforms(to: $0) }
    }

    func register(url selectedURL: URL, maximumPixelSize: CGSize) async throws -> WallpaperAsset {
        let displayName = selectedURL.deletingPathExtension().lastPathComponent
        let bookmark = try await permissionStore.createBookmark(for: selectedURL)
        try await permissionStore.storeBookmark(bookmark)

        do {
            let resolvedURL = try await permissionStore.resolveBookmark(id: bookmark.id)
            let result: Result<WallpaperAsset, Error>
            do {
                result = .success(
                    try await buildAsset(
                        displayName: displayName,
                        selectedURL: selectedURL,
                        resolvedURL: resolvedURL,
                        bookmarkID: bookmark.id,
                        maximumPixelSize: maximumPixelSize
                    )
                )
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

    private func buildAsset(
        displayName: String,
        selectedURL: URL,
        resolvedURL: URL,
        bookmarkID: UUID,
        maximumPixelSize: CGSize
    ) async throws -> WallpaperAsset {
        let metadata: AssetInspectionResult
        do {
            metadata = try await metadataLoader.inspect(url: resolvedURL)
        } catch {
            Log.importing.error("import rejected, unreadable video: \(error.localizedDescription, privacy: .public)")
            throw ImportError.unreadable(name: displayName)
        }

        let assetID = UUID()
        var stored: StoredPoster?
        if let poster = try? await posterFrameGenerator.generatePosterBox(for: resolvedURL, maxPixelSize: maximumPixelSize) {
            stored = try? await posterCacheStore.savePoster(poster, for: assetID)
        }

        Log.importing.info(
            "asset \(assetID.uuidString, privacy: .public): registered \(metadata.codecType, privacy: .public) \(Int(metadata.pixelSize.width))x\(Int(metadata.pixelSize.height)) \(metadata.frameRate, format: .fixed(precision: 2)) fps bitDepth=\(metadata.color.bitDepth) hdr=\(metadata.color.isHDR)"
        )

        return WallpaperAsset(
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
            optimizedPlayback: nil,
            hasAudio: metadata.hasAudio,
            posterImageRelativePath: stored?.posterPath,
            eligibility: metadata.playbackProfile,
            importedAt: .now,
            thumbnailRelativePath: stored?.thumbnailPath,
            optimizationState: .pending,
            sourceBitDepth: metadata.color.bitDepth,
            sourceIsHDR: metadata.color.isHDR
        )
    }

    /// Produces a playback rendition from the original file.
    func optimize(
        asset: WallpaperAsset,
        maximumPixelSize: CGSize,
        quality: UserPreferences.PlaybackQuality,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OptimizedPlaybackAsset {
        let sourceURL: URL
        do {
            sourceURL = try await permissionStore.resolveBookmark(id: asset.originalBookmarkID)
        } catch {
            throw ImportError.originalUnavailable(name: asset.displayName)
        }

        let result: Result<OptimizedPlaybackAsset, Error>
        do {
            guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                throw ImportError.originalUnavailable(name: asset.displayName)
            }
            result = .success(
                try await videoAssetOptimizer.optimize(
                    sourceURL: sourceURL,
                    assetID: asset.id,
                    maximumPixelSize: maximumPixelSize,
                    quality: quality,
                    recipe: asset.editRecipe,
                    progress: progress
                )
            )
        } catch {
            result = .failure(error)
        }

        await permissionStore.stopAccess(for: asset.originalBookmarkID)
        return try result.get()
    }
}

enum ImportError: LocalizedError, Equatable {
    case unreadable(name: String)
    case cannotBePlayedOrConverted(name: String)
    case originalUnavailable(name: String)
    case optimizationFailedPlayingOriginal(name: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            return String(localized: "“\(name)” could not be read as a video.")
        case let .cannotBePlayedOrConverted(name):
            return String(localized: "“\(name)” cannot be played or converted on this Mac, so it was not imported.")
        case let .originalUnavailable(name):
            return String(localized: "The original file of “\(name)” is no longer accessible.")
        case let .optimizationFailedPlayingOriginal(name):
            return String(localized: "“\(name)” could not be optimized. WallSync will play the original file instead.")
        }
    }
}
