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

    /// Describes the rendition that is played, when it differs from the source.
    static func renditionSummary(for asset: WallpaperAsset) -> String? {
        guard let rendition = asset.optimizedPlayback else { return nil }
        let size = "\(Int(rendition.pixelSize.width))x\(Int(rendition.pixelSize.height))"
        let details = "\(rendition.codecType) • \(size) • \(Int(rendition.frameRate.rounded())) fps • \(String(format: "%.1f", rendition.estimatedBitRate / 1_000_000)) Mbps"
        if rendition.isPassthrough {
            return String(localized: "Playing the original stream, not re-encoded: \(details)")
        }
        return String(localized: "Playing an optimized copy: \(details)")
    }

    static func statusText(for asset: WallpaperAsset, activity: ImportActivity? = nil) -> String {
        if let activity {
            if activity.isQueued {
                return String(localized: "Waiting to optimize")
            }
            let percent = Int((activity.progress * 100).rounded())
            if activity.isApplyingEdits {
                return String(localized: "Applying edits \(percent)%")
            }
            return activity.isReoptimization
                ? String(localized: "Improving quality \(percent)%")
                : String(localized: "Optimizing \(percent)%")
        }

        if asset.optimizationState == .pending && asset.optimizedPlayback == nil {
            return String(localized: "Waiting to optimize")
        }

        switch effectiveProfile(for: asset).tier {
        case .safe:
            return String(localized: "Ready to animate")
        case .warning:
            return String(localized: "Heavy for this Mac")
        case .unsupported:
            return String(localized: "Cannot be played")
        }
    }

    static func reasonLabel(for code: String) -> String {
        typealias Code = PlaybackEligibilityEvaluator.ReasonCode
        switch code {
        case Code.unsupportedFormat:
            return String(localized: "format not playable directly")
        case Code.exceedsDirectPlaybackLimits, Code.legacyExceedsLimits:
            return String(localized: "resolution or frame rate too high to play directly")
        case Code.highResolution:
            return String(localized: "4K or larger")
        case Code.highFrameRate:
            return String(localized: "more than 30 fps")
        case Code.highBitrate:
            return String(localized: "high bit rate")
        case Code.hardwareDecodeUncertain:
            return String(localized: "no hardware decoding")
        default:
            return code
        }
    }
}
