import AVFoundation
import Foundation

/// Builds the live preview of an edited loop for the editor.
///
/// This is a real-time composition, which the wallpaper itself never uses:
/// it exists only while the editor is open and is released when it closes.
/// The timeline is the same the optimizer writes (see
/// `VideoAssetOptimizer.editTranscode`), so what is previewed is what is
/// produced.
enum LoopPreviewBuilder {
    struct Preview {
        var composition: AVComposition
        var videoComposition: AVVideoComposition?
        var duration: TimeInterval
    }

    /// Largest side of the preview; the editor window is far smaller than a
    /// 4K frame and two layers are blended during the dissolve.
    static let maximumDimension: CGFloat = 1280

    static func make(asset: AVAsset, recipe: EditRecipe) async throws -> Preview {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AssetMetadataError.noVideoTrack
        }
        let (trackRange, naturalSize, transform, minFrameDuration) = try await track.load(
            .timeRange, .naturalSize, .preferredTransform, .minFrameDuration
        )
        let timing = recipe.timing(duration: trackRange.duration.seconds)
        func time(_ seconds: TimeInterval) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }

        let composition = AVMutableComposition()
        guard let mainTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoOptimizationError.readerSetupFailed
        }
        let start = trackRange.start + time(timing.start)
        let dissolve = time(timing.crossfade)
        let mainRange = CMTimeRange(start: start + dissolve, end: trackRange.start + time(timing.end))
        try mainTrack.insertTimeRange(mainRange, of: track, at: .zero)

        guard timing.crossfade > 0,
              let headTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            mainTrack.preferredTransform = transform
            return Preview(composition: composition, videoComposition: nil, duration: timing.outputDuration)
        }

        // The first `d` seconds of the selection fade in over the last `d`.
        let dissolveStart = mainRange.duration - dissolve
        try headTrack.insertTimeRange(CMTimeRange(start: start, duration: dissolve), of: track, at: dissolveStart)

        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let oriented = CGSize(width: abs(rect.width), height: abs(rect.height))
        let scale = min(1, maximumDimension / max(oriented.width, oriented.height))
        let renderSize = CGSize(
            width: max(2, (oriented.width * scale / 2).rounded(.down) * 2),
            height: max(2, (oriented.height * scale / 2).rounded(.down) * 2)
        )
        let upright = transform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: renderSize.width / oriented.width, y: renderSize.height / oriented.height))

        let mainLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: mainTrack)
        mainLayer.setTransform(upright, at: .zero)
        let headLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: headTrack)
        headLayer.setTransform(upright, at: .zero)
        headLayer.setOpacityRamp(
            fromStartOpacity: 0, toEndOpacity: 1,
            timeRange: CMTimeRange(start: dissolveStart, duration: dissolve)
        )

        let body = AVMutableVideoCompositionInstruction()
        body.timeRange = CMTimeRange(start: .zero, duration: dissolveStart)
        body.layerInstructions = [mainLayer]
        let seam = AVMutableVideoCompositionInstruction()
        seam.timeRange = CMTimeRange(start: dissolveStart, duration: dissolve)
        seam.layerInstructions = [headLayer, mainLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = minFrameDuration.isValid && minFrameDuration.seconds > 0
            ? minFrameDuration
            : CMTime(value: 1, timescale: 30)
        videoComposition.instructions = dissolveStart.seconds > 0 ? [body, seam] : [seam]

        return Preview(composition: composition, videoComposition: videoComposition, duration: timing.outputDuration)
    }
}
