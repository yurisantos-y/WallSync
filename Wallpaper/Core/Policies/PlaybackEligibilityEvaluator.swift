import Foundation

struct PlaybackEligibilityEvaluator {
    enum ReasonCode {
        static let unsupportedFormat = "unsupported_format"
        static let exceedsDirectPlaybackLimits = "exceeds_direct_playback_limits"
        /// Written by earlier versions; still present in stored catalogs.
        static let legacyExceedsLimits = "exceeds_mvp_limits"
        static let highResolution = "high_resolution"
        static let highFrameRate = "high_frame_rate"
        static let highBitrate = "high_bitrate"
        static let hardwareDecodeUncertain = "hardware_decode_uncertain"
    }

    /// The profile of what will actually be played: the optimized rendition
    /// when one exists, otherwise the original file.
    func effectiveProfile(for asset: WallpaperAsset) -> PlaybackProfile {
        guard let optimized = asset.optimizedPlayback else {
            return asset.eligibility
        }

        return profile(
            containerType: "mp4",
            codecType: optimized.codecType,
            pixelSize: optimized.pixelSize,
            frameRate: optimized.frameRate,
            estimatedBitRate: optimized.estimatedBitRate,
            hardwareDecodeLikely: true,
            enforcesDirectPlaybackLimits: false
        )
    }

    func profile(
        containerType: String,
        codecType: String,
        pixelSize: CGSize,
        frameRate: Double,
        estimatedBitRate: Double,
        hardwareDecodeLikely: Bool,
        enforcesDirectPlaybackLimits: Bool = true
    ) -> PlaybackProfile {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let is4KOrAbove = width >= 3840 || height >= 2160
        let isHighFrameRate = frameRate > 30.0
        let isHighBitrate = estimatedBitRate > 20_000_000
        let isHeavy = is4KOrAbove || isHighFrameRate || isHighBitrate || !hardwareDecodeLikely

        let normalizedContainer = containerType.lowercased()
        let normalizedCodec = codecType.lowercased()

        let supportedContainer = ["mp4", "mov", "m4v"].contains(normalizedContainer)
        let supportedCodec = normalizedCodec.contains("h264") || normalizedCodec.contains("hevc")

        guard !enforcesDirectPlaybackLimits || (supportedContainer && supportedCodec) else {
            return PlaybackProfile(
                tier: .unsupported,
                hardwareDecodeLikely: hardwareDecodeLikely,
                reasonCodes: [ReasonCode.unsupportedFormat],
                isHeavy: true,
                recommendedMode: .unsupported
            )
        }

        if enforcesDirectPlaybackLimits && (frameRate > 60 || width > 4096 || height > 2304) {
            return PlaybackProfile(
                tier: .unsupported,
                hardwareDecodeLikely: hardwareDecodeLikely,
                reasonCodes: [ReasonCode.exceedsDirectPlaybackLimits],
                isHeavy: true,
                recommendedMode: .unsupported
            )
        }

        if isHeavy {
            return PlaybackProfile(
                tier: .warning,
                hardwareDecodeLikely: hardwareDecodeLikely,
                reasonCodes: warningReasonCodes(
                    is4KOrAbove: is4KOrAbove,
                    isHighFrameRate: isHighFrameRate,
                    isHighBitrate: isHighBitrate,
                    hardwareDecodeLikely: hardwareDecodeLikely
                ),
                isHeavy: true,
                recommendedMode: .posterOnly
            )
        }

        return PlaybackProfile(
            tier: .safe,
            hardwareDecodeLikely: hardwareDecodeLikely,
            reasonCodes: [],
            isHeavy: false,
            recommendedMode: .animate
        )
    }

    private func warningReasonCodes(
        is4KOrAbove: Bool,
        isHighFrameRate: Bool,
        isHighBitrate: Bool,
        hardwareDecodeLikely: Bool
    ) -> [String] {
        var reasons: [String] = []
        if is4KOrAbove { reasons.append("high_resolution") }
        if isHighFrameRate { reasons.append("high_frame_rate") }
        if isHighBitrate { reasons.append("high_bitrate") }
        if !hardwareDecodeLikely { reasons.append("hardware_decode_uncertain") }
        return reasons
    }
}
