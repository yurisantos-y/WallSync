import Foundation

struct OptimizedPlaybackAsset: Codable, Hashable, Sendable {
    var relativePath: String
    var codecType: String
    var pixelSize: CGSize
    var frameRate: Double
    var estimatedBitRate: Double
    var duration: TimeInterval
}

struct WallpaperAsset: Codable, Identifiable, Hashable, Sendable {
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

    var resolutionDescription: String {
        "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}
