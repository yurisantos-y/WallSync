import Foundation

enum AssetInspector {
    /// What will actually be played: the optimized rendition when it exists.
    static func effectiveProfile(for asset: WallpaperAsset) -> PlaybackProfile {
        PlaybackEligibilityEvaluator().effectiveProfile(for: asset)
    }

    static func technicalSummary(for asset: WallpaperAsset) -> String {
        streamSummary(
            container: asset.containerType,
            codec: asset.codecType,
            pixelSize: asset.pixelSize,
            frameRate: asset.frameRate,
            bitRate: asset.estimatedBitRate
        )
    }

    /// Describes the rendition that is played, when it differs from the source.
    static func renditionSummary(for asset: WallpaperAsset) -> String? {
        guard let rendition = asset.optimizedPlayback else { return nil }
        let details = streamSummary(
            container: nil,
            codec: rendition.codecType,
            pixelSize: rendition.pixelSize,
            frameRate: rendition.frameRate,
            bitRate: rendition.estimatedBitRate
        )
        if rendition.isPassthrough {
            return String(localized: "Playing the original stream, not re-encoded: \(details)")
        }
        return String(localized: "Playing an optimized copy: \(details)")
    }

    private static func streamSummary(
        container: String?, codec: String, pixelSize: CGSize, frameRate: Double, bitRate: Double
    ) -> String {
        var parts: [String] = []
        if let container, !container.isEmpty { parts.append(container.uppercased()) }
        parts.append(codecName(codec))
        parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))")
        parts.append("\(Int(frameRate.rounded())) fps")
        parts.append("\(String(format: "%.1f", bitRate / 1_000_000)) Mbps")
        return parts.joined(separator: " · ")
    }

    /// The name people know a codec by, instead of its four-character code.
    static func codecName(_ code: String) -> String {
        switch code.lowercased().trimmingCharacters(in: .whitespaces) {
        case "hvc1", "hev1", "dvh1", "dvhe": return "HEVC"
        case "avc1", "avc3": return "H.264"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case let value where value.hasPrefix("ap"): return "ProRes"
        default: return code
        }
    }

    /// The line under a thumbnail: length, size class and HDR.
    static func shortSummary(for asset: WallpaperAsset) -> String {
        var parts = [durationLabel(asset.optimizedPlayback?.duration ?? asset.duration), sizeClass(asset.pixelSize)]
        if asset.sourceIsHDR || asset.optimizedPlayback?.isHDR == true { parts.append("HDR") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func sizeClass(_ size: CGSize) -> String {
        let short = Int(min(size.width, size.height))
        switch short {
        case ..<1: return ""
        case 4000...: return "8K"
        case 2100...: return "4K"
        default: return "\(short)p"
        }
    }

    /// The edits of a wallpaper in a few words, or `nil` without edits.
    static func editSummary(for asset: WallpaperAsset) -> String? {
        let recipe = asset.editRecipe
        var parts: [String] = []
        if recipe.trim != nil { parts.append(String(localized: "Trimmed")) }
        if recipe.loopCrossfade > 0 { parts.append(String(localized: "Crossfade")) }
        if !recipe.watermarkRegions.isEmpty || recipe.crop != nil { parts.append(String(localized: "Logo removed")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
