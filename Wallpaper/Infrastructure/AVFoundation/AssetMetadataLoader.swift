import AVFoundation
import CoreMedia
import Foundation

struct AssetInspectionResult: Sendable {
    var containerType: String
    var codecType: String
    var pixelSize: CGSize
    var frameRate: Double
    var estimatedBitRate: Double
    var duration: TimeInterval
    var hasAudio: Bool
    var playbackProfile: PlaybackProfile
}

actor AssetMetadataLoader {
    private let capabilityInspector: VideoCapabilityInspector
    private let evaluator: PlaybackEligibilityEvaluator

    init(
        capabilityInspector: VideoCapabilityInspector = VideoCapabilityInspector(),
        evaluator: PlaybackEligibilityEvaluator = PlaybackEligibilityEvaluator()
    ) {
        self.capabilityInspector = capabilityInspector
        self.evaluator = evaluator
    }

    func inspect(url: URL) async throws -> AssetInspectionResult {
        let asset = AVURLAsset(url: url)
        async let durationTask = asset.load(.duration)
        async let videoTracksTask = asset.loadTracks(withMediaType: .video)
        async let audioTracksTask = asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await videoTracksTask

        guard let videoTrack = videoTracks.first else {
            throw AssetMetadataError.noVideoTrack
        }

        let duration = try await durationTask
        let audioTracks = try await audioTracksTask
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let estimatedBitRate = Double(try await videoTrack.load(.estimatedDataRate))
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)

        let transformed = naturalSize.applying(preferredTransform)
        let pixelSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))

        let codecType = formatDescriptions
            .first
            .map { CMFormatDescriptionGetMediaSubType($0) } ?? kCMVideoCodecType_H264

        let codecDescription = capabilityInspector.codecDescription(for: codecType)
        let hardwareDecodeLikely = capabilityInspector.hardwareDecodeLikely(for: codecType)
        let containerType = url.pathExtension.lowercased()

        let playbackProfile = evaluator.profile(
            containerType: containerType,
            codecType: codecDescription,
            pixelSize: pixelSize,
            frameRate: nominalFrameRate,
            estimatedBitRate: estimatedBitRate,
            hardwareDecodeLikely: hardwareDecodeLikely
        )

        return AssetInspectionResult(
            containerType: containerType,
            codecType: codecDescription,
            pixelSize: pixelSize,
            frameRate: nominalFrameRate,
            estimatedBitRate: estimatedBitRate,
            duration: duration.seconds,
            hasAudio: !audioTracks.isEmpty,
            playbackProfile: playbackProfile
        )
    }
}

enum AssetMetadataError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "O arquivo selecionado nao contem trilha de video."
        }
    }
}
