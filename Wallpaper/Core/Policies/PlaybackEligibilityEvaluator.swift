import Foundation

struct PlaybackEligibilityEvaluator {
    func profile(
        containerType: String,
        codecType: String,
        pixelSize: CGSize,
        frameRate: Double,
        estimatedBitRate: Double,
        hardwareDecodeLikely: Bool
    ) -> PlaybackProfile {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let is4KOrAbove = width >= 3840 || height >= 2160
        let isHighFrameRate = frameRate > 30.0
        let isHighBitrate = estimatedBitRate > 20_000_000
        let isHeavy = is4KOrAbove || isHighFrameRate || isHighBitrate || !hardwareDecodeLikely

        let normalizedContainer = containerType.lowercased()
        let normalizedCodec = codecType.lowercased()

        let supportedContainer = ["mp4", "mov"].contains(normalizedContainer)
        let supportedCodec = normalizedCodec.contains("h264") || normalizedCodec.contains("hevc")

        guard supportedContainer, supportedCodec else {
            return PlaybackProfile(
                tier: .unsupported,
                hardwareDecodeLikely: hardwareDecodeLikely,
                reasonCodes: ["unsupported_format"],
                isHeavy: true,
                recommendedMode: .unsupported
            )
        }

        if frameRate > 60 || width > 4096 || height > 2304 {
            return PlaybackProfile(
                tier: .unsupported,
                hardwareDecodeLikely: hardwareDecodeLikely,
                reasonCodes: ["exceeds_mvp_limits"],
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
