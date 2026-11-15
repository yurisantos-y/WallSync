import Foundation

/// The rendition the app actually plays: stored inside the app's container,
/// video only, sized for the displays that were connected when it was made.
struct OptimizedPlaybackAsset: Codable, Hashable, Sendable {
    var relativePath: String
    var codecType: String
    var pixelSize: CGSize
    var frameRate: Double
    var estimatedBitRate: Double
    var duration: TimeInterval
    /// Largest display pixel size this rendition was produced for. `nil` for
    /// renditions made before the value was recorded.
    var targetPixelSize: CGSize? = nil
    /// Frame-rate ceiling in effect when it was produced.
    var frameRateCap: Double? = nil
    /// The source stream was copied as is, without re-encoding.
    var isPassthrough: Bool = false
    var bitDepth: Int = 8
    var isHDR: Bool = false
    /// The edits this rendition was produced with. When the asset's recipe
    /// no longer matches, the rendition is stale and is produced again.
    var recipe: EditRecipe = .empty
    /// How each marked logo was removed (`WatermarkStrategy` raw values), in
    /// the order of the recipe's regions.
    var watermarkStrategies: [String] = []
}

extension OptimizedPlaybackAsset {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            relativePath: try container.decode(String.self, forKey: .relativePath),
            codecType: try container.decode(String.self, forKey: .codecType),
            pixelSize: try container.decode(CGSize.self, forKey: .pixelSize),
            frameRate: try container.decode(Double.self, forKey: .frameRate),
            estimatedBitRate: try container.decode(Double.self, forKey: .estimatedBitRate),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            targetPixelSize: try container.decodeIfPresent(CGSize.self, forKey: .targetPixelSize),
            frameRateCap: try container.decodeIfPresent(Double.self, forKey: .frameRateCap),
            isPassthrough: try container.decodeIfPresent(Bool.self, forKey: .isPassthrough) ?? false,
            bitDepth: try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 8,
            isHDR: try container.decodeIfPresent(Bool.self, forKey: .isHDR) ?? false,
            recipe: try container.decodeIfPresent(EditRecipe.self, forKey: .recipe) ?? .empty,
            watermarkStrategies: try container.decodeIfPresent([String].self, forKey: .watermarkStrategies) ?? []
        )
    }
}

struct WallpaperAsset: Codable, Identifiable, Hashable, Sendable {
    enum OptimizationState: String, Codable, Sendable {
        /// Waiting for, or in the middle of, its first optimization.
        case pending
        case ready
        /// Optimization failed; the original file is played when possible.
        case failed
    }

    let id: UUID
    var displayName: String
    var originalBookmarkID: UUID
    var originalPathHint: String
    var containerType: String
    var codecType: String
    var pixelSize: CGSize
    var frameRate: Double
    var estimatedBitRate: Double
    var duration: TimeInterval
    var optimizedPlayback: OptimizedPlaybackAsset? = nil
    var hasAudio: Bool
    var posterImageRelativePath: String?
    var eligibility: PlaybackProfile
    var importedAt: Date
    var thumbnailRelativePath: String? = nil
    var optimizationState: OptimizationState = .ready
    /// The original file could not be reached the last time a better
    /// rendition was needed; the current rendition is kept.
    var originalUnavailable: Bool = false
    var sourceBitDepth: Int = 8
    var sourceIsHDR: Bool = false
    /// Non-destructive edits applied by the optimizer.
    var editRecipe: EditRecipe = .empty
    /// 0.25 … 1. Slower playback decodes proportionally fewer frames.
    var playbackRate: Double = 1
    /// Per-wallpaper dimming; `nil` follows the global setting.
    var dimmingOverride: Double? = nil
    /// Last time the wallpaper was put on a display; orders the menu bar list.
    var lastUsedAt: Date? = nil

    static let playbackRateRange: ClosedRange<Double> = 0.25...1

    /// The rate actually handed to the player.
    var effectivePlaybackRate: Double {
        guard playbackRate.isFinite else { return 1 }
        return min(max(playbackRate, Self.playbackRateRange.lowerBound), Self.playbackRateRange.upperBound)
    }

    /// Exists, optimized, and therefore allowed into a playlist rotation.
    var isReadyForRotation: Bool {
        optimizationState == .ready && optimizedPlayback != nil
    }

    var resolutionDescription: String {
        "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}

extension WallpaperAsset {
    /// Tolerant decoding so catalogs written by earlier versions keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let optimizedPlayback = try container.decodeIfPresent(OptimizedPlaybackAsset.self, forKey: .optimizedPlayback)

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            originalBookmarkID: try container.decode(UUID.self, forKey: .originalBookmarkID),
            originalPathHint: try container.decode(String.self, forKey: .originalPathHint),
            containerType: try container.decode(String.self, forKey: .containerType),
            codecType: try container.decode(String.self, forKey: .codecType),
            pixelSize: try container.decode(CGSize.self, forKey: .pixelSize),
            frameRate: try container.decode(Double.self, forKey: .frameRate),
            estimatedBitRate: try container.decode(Double.self, forKey: .estimatedBitRate),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            optimizedPlayback: optimizedPlayback,
            hasAudio: try container.decode(Bool.self, forKey: .hasAudio),
            posterImageRelativePath: try container.decodeIfPresent(String.self, forKey: .posterImageRelativePath),
            eligibility: try container.decode(PlaybackProfile.self, forKey: .eligibility),
            importedAt: try container.decode(Date.self, forKey: .importedAt),
            thumbnailRelativePath: try container.decodeIfPresent(String.self, forKey: .thumbnailRelativePath),
            // Assets from versions without this field: optimized ones are
            // ready, the rest get optimized in the background.
            optimizationState: (try? container.decodeIfPresent(OptimizationState.self, forKey: .optimizationState))
                ?? (optimizedPlayback == nil ? .pending : .ready),
            originalUnavailable: try container.decodeIfPresent(Bool.self, forKey: .originalUnavailable) ?? false,
            sourceBitDepth: try container.decodeIfPresent(Int.self, forKey: .sourceBitDepth) ?? 8,
            sourceIsHDR: try container.decodeIfPresent(Bool.self, forKey: .sourceIsHDR) ?? false,
            editRecipe: try container.decodeIfPresent(EditRecipe.self, forKey: .editRecipe) ?? .empty,
            playbackRate: try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1,
            dimmingOverride: try container.decodeIfPresent(Double.self, forKey: .dimmingOverride),
            lastUsedAt: try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        )
    }
}
