import CoreMedia
import Foundation
import VideoToolbox

struct VideoCapabilityInspector {
    func hardwareDecodeLikely(for codec: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codec)
    }

    func codecDescription(for codec: CMVideoCodecType) -> String {
        switch codec {
        case kCMVideoCodecType_H264:
            return "H264"
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422:
            return "ProRes"
        default:
            return codec.fourCharacterCode
        }
    }
}

private extension UInt32 {
    var fourCharacterCode: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]

        return String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .controlCharacters) ?? "\(self)"
    }
}
