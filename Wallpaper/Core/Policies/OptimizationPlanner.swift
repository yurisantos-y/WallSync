import CoreGraphics
import Foundation

/// What the optimizer knows about the source stream.
struct SourceVideoDescription: Equatable, Sendable {
    var codec: String
    /// Display size, after applying the track's rotation.
    var pixelSize: CGSize
    var frameRate: Double
    var bitRate: Double
    var bitDepth: Int
    var isHDR: Bool
    var hardwareDecodable: Bool
    /// The track carries a rotation / flip that must be baked in.
    var hasTransform: Bool
}

struct OptimizationTarget: Equatable, Sendable {
    /// Pixel size of the largest connected display.
    var maximumPixelSize: CGSize
    var quality: UserPreferences.PlaybackQuality
    var hevcHardwareAvailable: Bool = true
}

enum OptimizedCodec: String, Equatable, Sendable {
    case hevc = "HEVC"
    case h264 = "H264"
}

struct TranscodePlan: Equatable, Sendable {
    var codec: OptimizedCodec
    var pixelSize: CGSize
    var frameRate: Double
    var bitRate: Double
    var isTenBit: Bool
    var preservesHDR: Bool
}

enum OptimizationPlan: Equatable, Sendable {
    /// Copy the compressed video samples unchanged (audio dropped).
    case passthrough
    case transcode(TranscodePlan)
}

/// Pure decisions of the video optimizer: whether to re-encode at all, and
/// with which resolution, frame rate, bit rate and bit depth.
enum OptimizationPlanner {
    private enum Constant {
        static let bitsPerPixelFrame = 0.07
        static let minimumBitRate = 4_000_000.0
        static let maximumBitRate = 18_000_000.0
        /// A source may carry up to this multiple of the target bit rate and
        /// still be copied instead of re-encoded: re-encoding costs quality
        /// and import time, while decode energy grows slowly with bit rate.
        static let passthroughBitRateTolerance = 2.0
        static let frameRateTolerance = 0.5
    }

    static func plan(source: SourceVideoDescription, target: OptimizationTarget) -> OptimizationPlan {
        let targetSize = targetPixelSize(sourcePixelSize: source.pixelSize, maximumPixelSize: target.maximumPixelSize)
        let frameRate = targetFrameRate(sourceFrameRate: source.frameRate, quality: target.quality)
        let codecName = source.codec.lowercased()
        let isTenBitSource = source.bitDepth >= 10

        let codecIsSuitable = (codecName.contains("hevc") || (codecName.contains("h264") && !isTenBitSource))
            && source.hardwareDecodable
        let sizeFits = Int(source.pixelSize.width) <= Int(targetSize.width)
            && Int(source.pixelSize.height) <= Int(targetSize.height)
            && Int(source.pixelSize.width) % 2 == 0
            && Int(source.pixelSize.height) % 2 == 0
        let frameRateFits = source.frameRate > 0
            && source.frameRate <= target.quality.maximumFrameRate + Constant.frameRateTolerance
        let bitRateCeiling = targetBitRate(
            sourceBitRate: 0,
            pixelSize: targetSize,
            frameRate: frameRate,
            isTenBit: isTenBitSource
        ) * Constant.passthroughBitRateTolerance
        let bitRateFits = source.bitRate > 0 && source.bitRate <= bitRateCeiling

        if codecIsSuitable && sizeFits && frameRateFits && bitRateFits && !source.hasTransform {
            return .passthrough
        }

        let codec: OptimizedCodec = target.hevcHardwareAvailable ? .hevc : .h264
        // 10-bit and HDR need HEVC Main10; H.264 output is always 8-bit SDR.
        let isTenBit = isTenBitSource && codec == .hevc

        return .transcode(
            TranscodePlan(
                codec: codec,
                pixelSize: targetSize,
                frameRate: frameRate,
                bitRate: targetBitRate(
                    sourceBitRate: source.bitRate,
                    pixelSize: targetSize,
                    frameRate: frameRate,
                    isTenBit: isTenBit
                ),
                isTenBit: isTenBit,
                preservesHDR: isTenBit && source.isHDR
            )
        )
    }

    /// The source scaled down (never up) to fit the largest display, with
    /// even dimensions as video encoders require.
    static func targetPixelSize(sourcePixelSize: CGSize, maximumPixelSize: CGSize) -> CGSize {
        guard sourcePixelSize.width > 0,
              sourcePixelSize.height > 0,
              maximumPixelSize.width > 0,
              maximumPixelSize.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }

        let scale = min(1, maximumPixelSize.width / sourcePixelSize.width, maximumPixelSize.height / sourcePixelSize.height)
        return CGSize(
            width: evenDimension(sourcePixelSize.width * scale),
            height: evenDimension(sourcePixelSize.height * scale)
        )
    }

    static func targetFrameRate(sourceFrameRate: Double, quality: UserPreferences.PlaybackQuality) -> Double {
        min(max(sourceFrameRate, 1), quality.maximumFrameRate)
    }

    static func targetBitRate(
        sourceBitRate: Double,
        pixelSize: CGSize,
        frameRate: Double,
        isTenBit: Bool = false
    ) -> Double {
        // More than 30 fps and 10-bit samples both need head-room.
        let ceiling = Constant.maximumBitRate * (frameRate > 30.5 ? 1.5 : 1) * (isTenBit ? 1.2 : 1)
        let calculated = pixelSize.width * pixelSize.height * frameRate * Constant.bitsPerPixelFrame * (isTenBit ? 1.2 : 1)
        let clamped = min(max(calculated, Constant.minimumBitRate), ceiling)

        guard sourceBitRate > 0 else {
            return clamped
        }

        return min(sourceBitRate, clamped)
    }

    /// Whether a better rendition can be produced now than the one on disk —
    /// a larger display was connected, or the frame-rate ceiling was raised —
    /// and the source actually has the extra pixels or frames to offer.
    static func needsReoptimization(
        asset: WallpaperAsset,
        maximumPixelSize: CGSize,
        quality: UserPreferences.PlaybackQuality
    ) -> Bool {
        guard asset.optimizationState == .ready, let current = asset.optimizedPlayback else {
            return false
        }

        let idealSize = targetPixelSize(sourcePixelSize: asset.pixelSize, maximumPixelSize: maximumPixelSize)
        let idealFrameRate = targetFrameRate(sourceFrameRate: asset.frameRate, quality: quality)

        let currentArea = current.pixelSize.width * current.pixelSize.height
        let idealArea = idealSize.width * idealSize.height
        let gainsResolution = idealArea > currentArea * 1.02
        let gainsFrameRate = idealFrameRate > current.frameRate + Constant.frameRateTolerance

        return gainsResolution || gainsFrameRate
    }

    private static func evenDimension(_ value: CGFloat) -> CGFloat {
        max(2, CGFloat(Int(value.rounded(.down)) / 2 * 2))
    }
}

extension Array where Element == DisplayTarget {
    /// Pixel size of the largest display, the upper bound for optimized video.
    var largestPixelSize: CGSize {
        map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 1920, height: 1080)
    }
}
