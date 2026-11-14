import Foundation

enum AssetInspector {
    /// What will actually be played: the optimized rendition when it exists.
    static func effectiveProfile(for asset: WallpaperAsset) -> PlaybackProfile {
        PlaybackEligibilityEvaluator().effectiveProfile(for: asset)
    }

    static func technicalSummary(for asset: WallpaperAsset) -> String {
        let bitrateMbps = asset.estimatedBitRate / 1_000_000
        return "\(asset.containerType.uppercased()) • \(asset.codecType) • \(asset.resolutionDescription) • \(Int(asset.frameRate.rounded())) fps • \(String(format: "%.1f", bitrateMbps)) Mbps"
    }

    static func statusText(for asset: WallpaperAsset) -> String {
        switch effectiveProfile(for: asset).tier {
        case .safe:
            return String(localized: "Ready to animate")
        case .warning:
            return String(localized: "Heavy for this Mac")
        case .unsupported:
            return String(localized: "Cannot be played")
        }
    }
}
