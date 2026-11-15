import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Runs the logo remover on a few moments of a video for the editor:
/// automatic detection of the logo, and before / after stills. Uses the
/// same analysis and the same GPU kernels as the optimizer, at a reduced
/// size so the answer comes quickly. Off the main thread; cancellable.
enum WatermarkPreviewer {
    struct Pair: @unchecked Sendable {
        var time: TimeInterval
        var before: CGImage
        var after: CGImage
    }

    struct Result: Sendable {
        var pairs: [Pair]
        /// One entry per region that is inside the picture.
        var strategies: [WatermarkStrategy]
    }

    static let maximumDimension: CGFloat = 960

    /// Proposes regions for fixed logos.
    static func detect(url: URL, progress: @Sendable (Double) -> Void = { _ in }) async throws -> [CGRect] {
        let description = try await FrameSampler.describe(url: url)
        guard description.duration > 0.5 else { return [] }
        let aspect = description.orientedSize.width / max(description.orientedSize.height, 1)
        let width = 192
        let height = max(16, Int((CGFloat(width) / max(aspect, 0.1)).rounded()))
        let frames = try await FrameSampler.sample(
            url: url, range: 0...description.duration, step: description.duration / 20,
            width: width, height: height, progress: progress
        )
        return WatermarkDetector.detect(
            frames: frames.map { PlaneImage(width: width, height: height, pixels: $0.pixels) }
        ).regions
    }

    /// Before / after stills around `times`.
    static func render(
        url: URL,
        regions: [CGRect],
        crop: CGRect?,
        times: [TimeInterval],
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        guard let processor = PlaneProcessor() else { throw VideoOptimizationError.processingUnavailable }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AssetMetadataError.noVideoTrack
        }
        let (trackRange, naturalSize, transform, nominalFrameRate) = try await track.load(
            .timeRange, .naturalSize, .preferredTransform, .nominalFrameRate
        )
        let frameRate = Double(nominalFrameRate > 0 ? nominalFrameRate : 30)
        let duration = trackRange.duration.seconds

        // Upright, cropped, scaled down, even dimensions.
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let full = CGSize(width: abs(rect.width), height: abs(rect.height))
        let visible = crop.map {
            CGRect(x: $0.minX * full.width, y: $0.minY * full.height, width: $0.width * full.width, height: $0.height * full.height)
        } ?? CGRect(origin: .zero, size: full)
        let scale = min(1, maximumDimension / max(visible.width, visible.height))
        let renderSize = CGSize(
            width: max(2, (visible.width * scale / 2).rounded(.down) * 2),
            height: max(2, (visible.height * scale / 2).rounded(.down) * 2)
        )
        let upright = transform
            .concatenating(CGAffineTransform(translationX: -rect.minX - visible.minX, y: -rect.minY - visible.minY))
            .concatenating(CGAffineTransform(scaleX: renderSize.width / visible.width, y: renderSize.height / visible.height))

        func frames(from start: TimeInterval, length: TimeInterval, step: TimeInterval) throws -> [(CVPixelBuffer, TimeInterval)] {
            let reader = try AVAssetReader(asset: asset)
            let clampedStart = min(max(start, 0), max(duration - 0.05, 0))
            reader.timeRange = CMTimeRange(
                start: trackRange.start + CMTime(seconds: clampedStart, preferredTimescale: 60_000),
                duration: CMTime(seconds: max(min(length, duration - clampedStart), 0.05), preferredTimescale: 60_000)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(upright, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: trackRange.end)
            instruction.layerInstructions = [layer]
            let composition = AVMutableVideoComposition()
            composition.renderSize = renderSize
            composition.frameDuration = CMTime(seconds: step, preferredTimescale: 60_000)
            composition.instructions = [instruction]

            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [track],
                videoSettings: PlaneProcessor.bufferAttributes(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            )
            output.videoComposition = composition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw VideoOptimizationError.readerSetupFailed }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? VideoOptimizationError.readerSetupFailed }
            defer { reader.cancelReading() }

            var result: [(CVPixelBuffer, TimeInterval)] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    result.append((buffer, (CMSampleBufferGetPresentationTimeStamp(sample) - trackRange.start).seconds))
                }
            }
            return result
        }

        // Regions are given in the full picture; bring them into the crop.
        let localRegions = regions.compactMap { region -> CGRect? in
            guard let crop else { return region }
            let inside = region.intersection(crop)
            guard !inside.isNull, inside.width > 0, inside.height > 0 else { return nil }
            return CGRect(
                x: (inside.minX - crop.minX) / crop.width, y: (inside.minY - crop.minY) / crop.height,
                width: inside.width / crop.width, height: inside.height / crop.height
            )
        }

        let samples = try frames(from: 0, length: duration, step: max(duration / 24, 1 / frameRate)).map(\.0)
        progress(0.3)
        let plans = try WatermarkRemover.plan(regions: localRegions, samples: samples, processor: processor)

        var pairs: [Pair] = []
        var strategies = plans.map(\.strategy)
        let frameBytes = Int(renderSize.width * renderSize.height) * 3 / 2
        for (index, time) in times.enumerated() {
            // A short burst, so that neighbouring frames are available.
            let burst = try frames(from: time - 0.7, length: 1.4, step: 1 / frameRate)
            guard !burst.isEmpty else { continue }
            let remover = WatermarkRemover(processor: processor, plans: plans, frameRate: frameRate, frameBytes: frameBytes)
            var outputs: [CVPixelBuffer] = []
            for (buffer, stamp) in burst {
                remover.push(buffer, time: CMTime(seconds: stamp, preferredTimescale: 60_000))
                while let ready = try remover.pop() { outputs.append(ready.frame) }
            }
            remover.finish()
            while let ready = try remover.pop() { outputs.append(ready.frame) }

            let middle = min(burst.count / 2, outputs.count - 1)
            if middle >= 0, let before = image(burst[middle].0), let after = image(outputs[middle]) {
                pairs.append(Pair(time: burst[middle].1, before: before, after: after))
            }
            // Report "from neighbouring frames" when any moment could use it.
            for (region, used) in remover.usedStrategies.enumerated() where used == .temporal {
                strategies[region] = .temporal
            }
            progress(0.3 + 0.7 * Double(index + 1) / Double(times.count))
        }

        return Result(pairs: pairs, strategies: strategies)
    }

    private static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }
}
