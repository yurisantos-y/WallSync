import AVFoundation
import CoreMedia
import Foundation

/// Colour and bit-depth facts about a video track.
struct VideoColorDescription: Hashable, Sendable {
    var bitDepth: Int
    var colorPrimaries: String?
    var transferFunction: String?
    var yCbCrMatrix: String?

    static let sdr = VideoColorDescription(bitDepth: 8, colorPrimaries: nil, transferFunction: nil, yCbCrMatrix: nil)

    var isHDR: Bool {
        guard let transferFunction else { return false }
        return transferFunction == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || transferFunction == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    var isTenBit: Bool { bitDepth >= 10 }

    /// `AVVideoColorPropertiesKey` value that carries the source colorimetry
    /// through a transcode. Falls back to Rec. 709 for untagged SDR.
    var videoColorProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: transferFunction ?? AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }
}

enum VideoFormatInspector {
    static func colorDescription(of format: CMFormatDescription) -> VideoColorDescription {
        let extensions = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]

        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String

        var description = VideoColorDescription(
            bitDepth: 8,
            colorPrimaries: primaries,
            transferFunction: transfer,
            yCbCrMatrix: matrix
        )

        if let bits = (extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue, bits > 0 {
            description.bitDepth = bits
        } else if description.isHDR {
            // HLG and PQ are only defined for 10 bits and above.
            description.bitDepth = 10
        }

        return description
    }

    static func colorDescription(of track: AVAssetTrack) async -> VideoColorDescription {
        guard let format = try? await track.load(.formatDescriptions).first else { return .sdr }
        return colorDescription(of: format)
    }
}
