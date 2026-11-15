import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Produces the rendition the app plays: video only, inside the app's
/// container, no larger than the biggest display, hardware-decodable.
actor VideoAssetOptimizer {
    private let fileManager: FileManager
    private let capabilityInspector: VideoCapabilityInspector
    private let optimizedDirectory: URL

    init(
        storage: StorageLocations,
        fileManager: FileManager = .default,
        capabilityInspector: VideoCapabilityInspector = VideoCapabilityInspector()
    ) {
        self.fileManager = fileManager
        self.capabilityInspector = capabilityInspector
        self.optimizedDirectory = storage.optimizedDirectory
    }

    /// - Parameter progress: called with values from 0 to 1 as work advances.
    /// - Throws: `CancellationError` when the task is cancelled. No partial
    ///   file is left behind on cancellation or failure.
    func optimize(
        sourceURL: URL,
        assetID: UUID,
        maximumPixelSize: CGSize,
        quality: UserPreferences.PlaybackQuality,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> OptimizedPlaybackAsset {
        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw AssetMetadataError.noVideoTrack
        }

        let (naturalSize, preferredTransform, timeRange, nominalFrameRate, dataRate, minFrameDuration, formats) =
            try await videoTrack.load(
                .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate,
                .estimatedDataRate, .minFrameDuration, .formatDescriptions
            )
        guard let format = formats.first, timeRange.duration.seconds > 0 else {
            throw VideoOptimizationError.readerSetupFailed
        }

        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let color = VideoFormatInspector.colorDescription(of: format)

        let source = SourceVideoDescription(
            codec: capabilityInspector.codecDescription(for: codec),
            pixelSize: orientedSize,
            frameRate: Double(nominalFrameRate),
            bitRate: Double(dataRate),
            bitDepth: color.bitDepth,
            isHDR: color.isHDR,
            hardwareDecodable: capabilityInspector.hardwareDecodeLikely(for: codec),
            hasTransform: !preferredTransform.isIdentity
        )
        let target = OptimizationTarget(
            maximumPixelSize: maximumPixelSize,
            quality: quality,
            hevcHardwareAvailable: capabilityInspector.hardwareDecodeLikely(for: kCMVideoCodecType_HEVC)
        )
        let plan = OptimizationPlanner.plan(source: source, target: target)

        // A unique name per rendition lets a new one be written while the
        // previous one is still playing.
        let revision = UUID().uuidString.prefix(8).lowercased()
        let fileExtension: String
        switch plan {
        case .passthrough: fileExtension = "mov"
        case .transcode: fileExtension = "mp4"
        }
        let fileName = "\(assetID.uuidString)-\(revision).\(fileExtension)"
        let destination = optimizedDirectory.appendingPathComponent(fileName)
        let partial = optimizedDirectory.appendingPathComponent(".\(fileName).partial")

        try? fileManager.createDirectory(at: optimizedDirectory, withIntermediateDirectories: true)
        removePartialFiles(named: partial.lastPathComponent)

        let signpost = Signpost.begin(Signpost.Name.transcode)
        defer { Signpost.end(Signpost.Name.transcode, signpost) }

        do {
            switch plan {
            case .passthrough:
                Log.importing.info("asset \(assetID.uuidString, privacy: .public): source already suitable, copying video stream without re-encoding")
                try await remux(
                    sourceAsset: sourceAsset,
                    videoTrack: videoTrack,
                    format: format,
                    timeRange: timeRange,
                    destination: partial,
                    progress: progress
                )
            case let .transcode(transcodePlan):
                Log.importing.info(
                    "asset \(assetID.uuidString, privacy: .public): transcoding to \(transcodePlan.codec.rawValue, privacy: .public) \(Int(transcodePlan.pixelSize.width))x\(Int(transcodePlan.pixelSize.height)) @ \(transcodePlan.frameRate, format: .fixed(precision: 2)) fps, \(Int(transcodePlan.bitRate / 1000)) kbps, tenBit=\(transcodePlan.isTenBit) hdr=\(transcodePlan.preservesHDR)"
                )
                try await transcode(
                    sourceAsset: sourceAsset,
                    videoTrack: videoTrack,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    timeRange: timeRange,
                    minFrameDuration: minFrameDuration,
                    sourceFrameRate: Double(nominalFrameRate),
                    sourceColor: color,
                    plan: transcodePlan,
                    destination: partial,
                    progress: progress
                )
            }

            try Task.checkCancellation()
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            removePartialFiles(named: partial.lastPathComponent)
            Log.importing.error("asset \(assetID.uuidString, privacy: .public): optimization did not complete: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        progress(1)
        return try await describeOutput(
            at: destination,
            relativePath: "\(StorageLocations.optimizedDirectoryName)/\(fileName)",
            plan: plan,
            source: source,
            target: target
        )
    }

    /// Removes the partial output and the scratch files AVAssetWriter keeps
    /// next to it (`<name>.sb-…`), so a cancelled or failed run leaves nothing.
    private func removePartialFiles(named partialName: String) {
        let names = (try? fileManager.contentsOfDirectory(atPath: optimizedDirectory.path)) ?? []
        for name in names where name.hasPrefix(partialName) {
            try? fileManager.removeItem(at: optimizedDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Output description

    /// Reads the finished file back so the catalog records what was really
    /// produced rather than what was requested.
    private func describeOutput(
        at url: URL,
        relativePath: String,
        plan: OptimizationPlan,
        source: SourceVideoDescription,
        target: OptimizationTarget
    ) async throws -> OptimizedPlaybackAsset {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoOptimizationError.writerFailed
        }
        let (naturalSize, frameRate, dataRate, timeRange, formats) = try await track.load(
            .naturalSize, .nominalFrameRate, .estimatedDataRate, .timeRange, .formatDescriptions
        )
        let color = formats.first.map(VideoFormatInspector.colorDescription(of:)) ?? .sdr

        let codecName: String
        let isPassthrough: Bool
        switch plan {
        case .passthrough:
            codecName = source.codec
            isPassthrough = true
        case let .transcode(transcodePlan):
            codecName = transcodePlan.codec.rawValue
            isPassthrough = false
        }

        return OptimizedPlaybackAsset(
            relativePath: relativePath,
            codecType: codecName,
            pixelSize: CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height)),
            frameRate: Double(frameRate),
            estimatedBitRate: Double(dataRate),
            duration: timeRange.duration.seconds,
            targetPixelSize: target.maximumPixelSize,
            frameRateCap: target.quality.maximumFrameRate,
            isPassthrough: isPassthrough,
            bitDepth: color.bitDepth,
            isHDR: color.isHDR
        )
    }

    // MARK: - Passthrough

    /// Copies the compressed video samples into a new file, dropping audio.
    /// Lossless and fast; playback no longer depends on the original file.
    private func remux(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        format: CMFormatDescription,
        timeRange: CMTimeRange,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: sourceAsset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoOptimizationError.readerSetupFailed
        }
        reader.add(readerOutput)

        // QuickTime accepts every H.264 / HEVC sample description unchanged.
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw VideoOptimizationError.writerSetupFailed
        }
        writer.add(writerInput)

        try await TranscodeSession(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            timeRange: timeRange,
            progress: progress
        ).run()
    }

    // MARK: - Transcode

    private func transcode(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        timeRange: CMTimeRange,
        minFrameDuration: CMTime,
        sourceFrameRate: Double,
        sourceColor: VideoColorDescription,
        plan: TranscodePlan,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Output colorimetry: HDR and wide-gamut sources keep their own
        // primaries, transfer function and matrix; an HDR source that cannot
        // stay HDR is converted to Rec. 709. SDR stays SDR.
        let outputColor: VideoColorDescription
        if sourceColor.isHDR && !plan.preservesHDR {
            outputColor = .sdr
        } else {
            outputColor = sourceColor
        }
        let colorProperties = outputColor.videoColorProperties

        // Keep the source cadence exactly when the frame rate is not being
        // reduced (29.97 stays 29.97 instead of being resampled to 30).
        let frameDuration: CMTime
        if sourceFrameRate <= plan.frameRate + 0.01, minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            frameDuration = minFrameDuration
        } else {
            frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(plan.frameRate.rounded()))))
        }

        let reader = try AVAssetReader(asset: sourceAsset)
        let videoComposition = Self.videoComposition(
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            timeRange: timeRange,
            targetPixelSize: plan.pixelSize,
            frameDuration: frameDuration,
            colorProperties: colorProperties
        )

        // Biplanar YUV at the source bit depth: no round trip through 8-bit
        // BGRA, so 10-bit and HDR content keeps its precision.
        let pixelFormat = plan.isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ]
        )
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoOptimizationError.readerSetupFailed
        }
        reader.add(readerOutput)

        let profileLevel: String
        switch (plan.codec, plan.isTenBit) {
        case (.hevc, true): profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case (.hevc, false): profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case (.h264, _): profileLevel = AVVideoProfileLevelH264HighAutoLevel
        }

        // Encoding parameters chosen for an endlessly looping wallpaper:
        //
        // * No frame reordering (no B-frames). Every frame depends only on
        //   earlier ones, so the decoder never holds frames back: the last
        //   frame of the loop is presented exactly at the end of the file and
        //   the first frame of the next pass follows with no reorder delay at
        //   the seam. It also minimises decoder latency and memory. The cost
        //   is a few percent of compression efficiency.
        //
        // * A keyframe at most every 4 seconds. A wallpaper is decoded
        //   linearly and never scrubbed, so frequent keyframes would only
        //   add bits (and decode work) for nothing; 4 s keeps the average
        //   bit rate low while still bounding how much has to be decoded to
        //   resume from a saved position after the player was unloaded. Each
        //   pass of the loop starts on the file's first keyframe regardless.
        let keyFrameIntervalSeconds = 4.0
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(plan.bitRate),
            AVVideoExpectedSourceFrameRateKey: Int(plan.frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: keyFrameIntervalSeconds,
            AVVideoMaxKeyFrameIntervalKey: Int((plan.frameRate * keyFrameIntervalSeconds).rounded()),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: profileLevel
        ]

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(plan.pixelSize.width),
                AVVideoHeightKey: Int(plan.pixelSize.height),
                AVVideoColorPropertiesKey: colorProperties,
                AVVideoCompressionPropertiesKey: compression
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw VideoOptimizationError.writerSetupFailed
        }
        writer.add(writerInput)

        try await TranscodeSession(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            timeRange: CMTimeRange(start: .zero, duration: timeRange.duration),
            progress: progress
        ).run()
    }

    private static func videoComposition(
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        timeRange: CMTimeRange,
        targetPixelSize: CGSize,
        frameDuration: CMTime,
        colorProperties: [String: String]
    ) -> AVMutableVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let scale = min(targetPixelSize.width / orientedSize.width, targetPixelSize.height / orientedSize.height)
        let translated = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        let scaled = translated.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.concatenating(
            CGAffineTransform(
                translationX: (targetPixelSize.width - orientedSize.width * scale) / 2,
                y: (targetPixelSize.height - orientedSize.height * scale) / 2
            )
        )

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(centered, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: timeRange.end)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = targetPixelSize
        composition.frameDuration = frameDuration
        composition.instructions = [instruction]
        composition.colorPrimaries = colorProperties[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = colorProperties[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = colorProperties[AVVideoYCbCrMatrixKey]
        return composition
    }

    // MARK: - Compatibility wrappers

    static func targetPixelSize(sourcePixelSize: CGSize, maximumPixelSize: CGSize) -> CGSize {
        OptimizationPlanner.targetPixelSize(sourcePixelSize: sourcePixelSize, maximumPixelSize: maximumPixelSize)
    }

    static func targetBitRate(sourceBitRate: Double, pixelSize: CGSize, frameRate: Double) -> Double {
        OptimizationPlanner.targetBitRate(sourceBitRate: sourceBitRate, pixelSize: pixelSize, frameRate: frameRate)
    }
}

/// Moves samples from a reader to a writer, driven by the writer's own
/// readiness callback (`requestMediaDataWhenReady`) instead of polling.
///
/// AVFoundation's reader and writer objects are not `Sendable`; this class is
/// the single owner and only touches them on its private serial queue once
/// `run()` has started.
private final class TranscodeSession: @unchecked Sendable {
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let timeRange: CMTimeRange
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "com.yurisantos.wallpaper.transcode", qos: .utility)

    private let lock = NSLock()
    private var isCancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReportedPercent = -1

    init(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        timeRange: CMTimeRange,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.writerInput = writerInput
        self.timeRange = timeRange
        self.progress = progress
    }

    func run() async throws {
        try Task.checkCancellation()

        guard reader.startReading() else {
            throw reader.error ?? VideoOptimizationError.readerSetupFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? VideoOptimizationError.writerSetupFailed
        }
        writer.startSession(atSourceTime: timeRange.start)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock { self.continuation = continuation }
                    writerInput.requestMediaDataWhenReady(on: queue) { [self] in
                        drain()
                    }
                }
            } onCancel: {
                lock.withLock { isCancelled = true }
                // Wake the queue even if the writer is not asking for data.
                queue.async { [self] in
                    if lock.withLock({ isCancelled }) {
                        finish(with: CancellationError())
                    }
                }
            }
        } catch {
            reader.cancelReading()
            // Let any in-flight append return before the writer is cancelled,
            // so its scratch file is closed by the time the caller cleans up.
            queue.sync {}
            writer.cancelWriting()
            throw error
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? VideoOptimizationError.readerFailed
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? VideoOptimizationError.writerFailed
        }
    }

    /// Runs on `queue` whenever the writer can take more samples.
    private func drain() {
        while writerInput.isReadyForMoreMediaData {
            if lock.withLock({ isCancelled }) {
                finish(with: CancellationError())
                return
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                finish(with: nil)
                return
            }

            guard writerInput.append(sampleBuffer) else {
                finish(with: writer.error ?? VideoOptimizationError.writerAppendFailed)
                return
            }

            report(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }

    private func report(_ time: CMTime) {
        guard timeRange.duration.seconds > 0, time.isValid else { return }
        let fraction = min(max((time - timeRange.start).seconds / timeRange.duration.seconds, 0), 0.99)
        let percent = Int(fraction * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        progress(fraction)
    }

    private func finish(with error: Error?) {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<Void, Error>? in
            let pending = self.continuation
            self.continuation = nil
            return pending
        }) else {
            return
        }

        writerInput.markAsFinished()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

enum VideoOptimizationError: LocalizedError {
    case readerSetupFailed
    case writerSetupFailed
    case writerAppendFailed
    case readerFailed
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .readerSetupFailed:
            return String(localized: "The video could not be opened for reading.")
        case .writerSetupFailed:
            return String(localized: "The optimized file could not be created.")
        case .writerAppendFailed:
            return String(localized: "A frame of the optimized video could not be written.")
        case .readerFailed:
            return String(localized: "Reading the original video failed.")
        case .writerFailed:
            return String(localized: "Writing the optimized video failed.")
        }
    }
}
