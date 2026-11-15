import AVFoundation
import CoreVideo
import Foundation

/// Reads small greyscale versions of a video's frames for analysis (loop
/// point suggestion, logo detection). Runs off the main thread; cancellable.
enum FrameSampler {
    struct Frame: Sendable {
        var time: TimeInterval
        /// Luma, row by row, 0 … 1.
        var pixels: [Float]
    }

    struct Description: Sendable {
        var duration: TimeInterval
        var frameRate: Double
        /// Display size, after applying the track's rotation.
        var orientedSize: CGSize
    }

    static func describe(url: URL) async throws -> Description {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AssetMetadataError.noVideoTrack
        }
        let (timeRange, frameRate, naturalSize, transform) = try await track.load(
            .timeRange, .nominalFrameRate, .naturalSize, .preferredTransform
        )
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return Description(
            duration: timeRange.duration.seconds,
            frameRate: Double(frameRate > 0 ? frameRate : 30),
            orientedSize: CGSize(width: abs(rect.width), height: abs(rect.height))
        )
    }

    /// Frames of `range` (seconds from the start of the video), at most one
    /// every `step` seconds, scaled to `width` × `height` and upright.
    static func sample(
        url: URL,
        range: ClosedRange<TimeInterval>,
        step: TimeInterval,
        width: Int,
        height: Int,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AssetMetadataError.noVideoTrack
        }
        let (trackRange, naturalSize, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let start = trackRange.start + CMTime(seconds: range.lowerBound, preferredTimescale: 60_000)
        let length = max(range.upperBound - range.lowerBound, 0.001)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: length, preferredTimescale: 60_000))

        // A composition output gives upright, scaled frames in one step.
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let oriented = CGSize(width: abs(rect.width), height: abs(rect.height))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            transform
                .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .concatenating(CGAffineTransform(scaleX: CGFloat(width) / oriented.width, y: CGFloat(height) / oriented.height)),
            at: .zero
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: trackRange.end)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(seconds: max(step, 1.0 / 120), preferredTimescale: 60_000)
        composition.instructions = [instruction]

        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoOptimizationError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoOptimizationError.readerSetupFailed }
        defer { reader.cancelReading() }

        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = (CMSampleBufferGetPresentationTimeStamp(sample) - trackRange.start).seconds
            frames.append(Frame(time: time, pixels: luma(of: buffer)))
            progress(min(max((time - range.lowerBound) / length, 0), 1))
        }
        try Task.checkCancellation()
        return frames
    }

    private static func luma(of buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                pixels[y * width + x] = Float(row[x]) / 255
            }
        }
        return pixels
    }
}

/// Finds loop points in a video file.
enum LoopPointAnalyzer {
    /// - Parameter progress: 0 … 1 while frames are read.
    static func suggest(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LoopSuggestion? {
        let description = try await FrameSampler.describe(url: url)
        let duration = description.duration
        guard duration > 1 else { return nil }

        // Candidates come from the first and last part of the video, so
        // most of it is kept.
        let window = min(duration * 0.4, 8)
        let step = max(1 / description.frameRate, 0.1)
        let size = (width: 48, height: 27)

        let head = try await FrameSampler.sample(
            url: url, range: 0...window, step: step, width: size.width, height: size.height
        ) { progress($0 * 0.5) }
        let tail = try await FrameSampler.sample(
            url: url, range: (duration - window)...duration, step: step, width: size.width, height: size.height
        ) { progress(0.5 + $0 * 0.5) }

        // The frame "after the end" of the video does not exist; the end of
        // the file is represented by its last frame one step later.
        var tailSamples = tail.map { LoopFrameSample(time: $0.time, pixels: $0.pixels) }
        if let last = tailSamples.last {
            tailSamples.append(LoopFrameSample(time: min(duration, last.time + step), pixels: last.pixels))
        }

        progress(1)
        return LoopPointScorer.suggest(
            head: head.map { LoopFrameSample(time: $0.time, pixels: $0.pixels) },
            tail: tailSamples,
            duration: duration,
            minimumLength: max(duration * 0.3, min(2, duration * 0.5))
        )
    }
}
