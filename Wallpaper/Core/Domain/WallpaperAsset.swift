import Foundation

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
    var hasAudio: Bool
    var posterImageRelativePath: String?
    var eligibility: PlaybackProfile
    var importedAt: Date

    var resolutionDescription: String {
        "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}
