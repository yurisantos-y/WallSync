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
        recipe: EditRecipe = .empty,
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
        // Edits are applied here, once; playback never sees the recipe.
        // The recipe is recorded on the rendition exactly as it was asked
        // for; what is applied is clamped to this track's real duration.
        let requestedRecipe = recipe
        let recipe = recipe.normalized(duration: timeRange.duration.seconds)
        let timing = recipe.timing(duration: timeRange.duration.seconds)
        let keptRange = CMTimeRange(
            start: timeRange.start + CMTime(seconds: timing.start, preferredTimescale: 60_000),
            end: timeRange.start + CMTime(seconds: timing.end, preferredTimescale: 60_000)
        )
        var trimIsKeyframeAligned = true
        if recipe.trim != nil {
            trimIsKeyframeAligned = (try? await videoTrack.load(.canProvideSampleCursors)) == true
                && Self.isKeyframeAligned(track: videoTrack, range: keptRange, trackEnd: timeRange.end, frameRate: Double(nominalFrameRate))
        }
        let plan = OptimizationPlanner.plan(
            source: source,
            target: target,
            recipe: recipe,
            trimIsKeyframeAligned: trimIsKeyframeAligned
        )

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

        // A reframed video has a logo outside the picture; regions that
        // are still marked add their own strategies after it.
        var watermarkStrategies: [WatermarkStrategy] = recipe.crop != nil ? [.reframe] : []

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
                    timeRange: recipe.trim == nil ? timeRange : keptRange,
                    destination: partial,
                    progress: progress
                )
            case let .transcode(transcodePlan) where !recipe.isEmpty:
                Log.importing.info(
                    "asset \(assetID.uuidString, privacy: .public): applying edits (trim=\(recipe.trim != nil) crossfade=\(recipe.loopCrossfade, format: .fixed(precision: 2))s marks=\(recipe.watermarkRegions.count) crop=\(recipe.crop != nil)) to \(transcodePlan.codec.rawValue, privacy: .public) \(Int(transcodePlan.pixelSize.width))x\(Int(transcodePlan.pixelSize.height))"
                )
                watermarkStrategies += try await editTranscode(
                    sourceAsset: sourceAsset,
                    videoTrack: videoTrack,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    timeRange: timeRange,
                    keptRange: keptRange,
                    crossfade: timing.crossfade,
                    crop: recipe.crop,
                    watermarkRegions: recipe.watermarkRegions,
                    minFrameDuration: minFrameDuration,
                    sourceFrameRate: Double(nominalFrameRate),
                    sourceColor: color,
                    plan: transcodePlan,
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
            target: target,
            recipe: requestedRecipe,
            watermarkStrategies: watermarkStrategies
        )
    }

    /// Whether `range` can be cut out of the compressed stream without
    /// decoding: it starts on a keyframe, and ends on one or at the end of
    /// the video. The track must be able to provide sample cursors.
    static func isKeyframeAligned(track: AVAssetTrack, range: CMTimeRange, trackEnd: CMTime, frameRate: Double) -> Bool {
        let tolerance = 0.5 / max(frameRate, 1)

        func isKeyframe(at time: CMTime) -> Bool {
            guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { return false }
            return abs((cursor.presentationTimeStamp - time).seconds) <= tolerance
                && cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue
        }

        guard isKeyframe(at: range.start) else { return false }
        return (trackEnd - range.end).seconds <= tolerance || isKeyframe(at: range.end)
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
        target: OptimizationTarget,
        recipe: EditRecipe = .empty,
        watermarkStrategies: [WatermarkStrategy] = []
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
            isHDR: color.isHDR,
            recipe: recipe,
            watermarkStrategies: watermarkStrategies.map(\.rawValue)
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
        // For a trimmed copy this is the kept range, which starts on a
        // keyframe; otherwise it is the whole track.
        reader.timeRange = timeRange
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

        let frameDuration = Self.frameDuration(
            sourceFrameRate: sourceFrameRate, minFrameDuration: minFrameDuration, plan: plan
        )

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

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.encoderSettings(plan: plan, colorProperties: colorProperties)
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

    /// Keeps the source cadence exactly when the frame rate is not being
    /// reduced (29.97 stays 29.97 instead of being resampled to 30).
    private static func frameDuration(sourceFrameRate: Double, minFrameDuration: CMTime, plan: TranscodePlan) -> CMTime {
        if sourceFrameRate <= plan.frameRate + 0.01, minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            return minFrameDuration
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(plan.frameRate.rounded()))))
    }

    private static func outputColor(sourceColor: VideoColorDescription, plan: TranscodePlan) -> VideoColorDescription {
        sourceColor.isHDR && !plan.preservesHDR ? .sdr : sourceColor
    }

    private static func encoderSettings(plan: TranscodePlan, colorProperties: [String: String]) -> [String: Any] {
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

        return [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(plan.pixelSize.width),
            AVVideoHeightKey: Int(plan.pixelSize.height),
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    // MARK: - Edits

    /// Re-encodes with the recipe applied.
    ///
    /// For a kept range `start ..< end` and a dissolve of `d` seconds the
    /// result lasts `(end - start) - d`. It plays `start + d ..< end`, and
    /// over its last `d` seconds the first `d` seconds of the range
    /// (`start ..< start + d`) fade in on top. The result therefore ends on
    /// the frame just before `start + d` and begins on the frame at
    /// `start + d`: the loop point is continuous, and `AVPlayerLooper`
    /// repeats it without a gap.
    ///
    /// Frames come out of the reader scaled, oriented and cropped by the
    /// video composition, in biplanar Y'CbCr at the output bit depth. Frames
    /// that need no processing go to the encoder untouched; the others are
    /// processed on the GPU in that same format (see `PlaneProcessor`).
    private func editTranscode(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        timeRange: CMTimeRange,
        keptRange: CMTimeRange,
        crossfade: TimeInterval,
        crop: CGRect?,
        watermarkRegions: [CGRect] = [],
        minFrameDuration: CMTime,
        sourceFrameRate: Double,
        sourceColor: VideoColorDescription,
        plan: TranscodePlan,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WatermarkStrategy] {
        let colorProperties = Self.outputColor(sourceColor: sourceColor, plan: plan).videoColorProperties
        let frameDuration = Self.frameDuration(
            sourceFrameRate: sourceFrameRate, minFrameDuration: minFrameDuration, plan: plan
        )
        let pixelFormat = plan.isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        func makeReader(range: CMTimeRange, frameDuration: CMTime = frameDuration) throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
            let reader = try AVAssetReader(asset: sourceAsset)
            reader.timeRange = range
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: PlaneProcessor.bufferAttributes(pixelFormat: pixelFormat)
            )
            output.videoComposition = Self.videoComposition(
                videoTrack: videoTrack,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                timeRange: timeRange,
                targetPixelSize: plan.pixelSize,
                frameDuration: frameDuration,
                colorProperties: colorProperties,
                crop: crop
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw VideoOptimizationError.readerSetupFailed }
            reader.add(output)
            return (reader, output)
        }

        let dissolve = CMTime(seconds: crossfade, preferredTimescale: 60_000)
        let hasDissolve = crossfade > 0
        let main = try makeReader(
            range: hasDissolve ? CMTimeRange(start: keptRange.start + dissolve, end: keptRange.end) : keptRange
        )
        let head = hasDissolve ? try makeReader(range: CMTimeRange(start: keptRange.start, duration: dissolve)) : nil

        var processor: PlaneProcessor?
        if hasDissolve || !watermarkRegions.isEmpty {
            guard let created = PlaneProcessor() else { throw VideoOptimizationError.processingUnavailable }
            processor = created
        }

        // Logo removal: look at frames spread over the video first, to
        // decide how each region is removed and to measure translucent marks.
        var mainRemover: WatermarkRemover?
        var headRemover: WatermarkRemover?
        if let processor, !watermarkRegions.isEmpty {
            // With a crop, regions are still given in the full picture.
            let regions = watermarkRegions.compactMap { region -> CGRect? in
                guard let crop else { return region }
                let visible = region.intersection(crop)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
                return CGRect(
                    x: (visible.minX - crop.minX) / crop.width, y: (visible.minY - crop.minY) / crop.height,
                    width: visible.width / crop.width, height: visible.height / crop.height
                )
            }
            let sampleCount = 24.0
            let sampler = try makeReader(
                range: keptRange,
                frameDuration: CMTime(seconds: max(keptRange.duration.seconds / sampleCount, frameDuration.seconds), preferredTimescale: 60_000)
            )
            guard sampler.0.startReading() else { throw sampler.0.error ?? VideoOptimizationError.readerSetupFailed }
            var samples: [CVPixelBuffer] = []
            while let sample = sampler.1.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if let buffer = CMSampleBufferGetImageBuffer(sample) { samples.append(buffer) }
            }
            sampler.0.cancelReading()

            let plans = try WatermarkRemover.plan(regions: regions, samples: samples, processor: processor)
            if !plans.isEmpty {
                // 4:2:0: one and a half samples per pixel, one or two bytes each.
                let frameBytes = Int(plan.pixelSize.width * plan.pixelSize.height) * 3 / 2 * (plan.isTenBit ? 2 : 1)
                let frameRate = 1 / max(frameDuration.seconds, 0.001)
                mainRemover = WatermarkRemover(processor: processor, plans: plans, frameRate: frameRate, frameBytes: frameBytes)
                if hasDissolve {
                    headRemover = WatermarkRemover(processor: processor, plans: plans, frameRate: frameRate, frameBytes: frameBytes)
                }
            }
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.encoderSettings(plan: plan, colorProperties: colorProperties)
        )
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(writerInput) else { throw VideoOptimizationError.writerSetupFailed }
        writer.add(writerInput)

        let outputDuration = keptRange.duration.seconds - crossfade
        try await EditSession(
            mainReader: main.0,
            mainOutput: main.1,
            headReader: head?.0,
            headOutput: head?.1,
            writer: writer,
            writerInput: writerInput,
            adaptor: adaptor,
            processor: processor,
            mainRemover: mainRemover,
            headRemover: headRemover,
            dissolveStart: outputDuration - crossfade,
            dissolveDuration: crossfade,
            frameDuration: frameDuration,
            outputDuration: outputDuration,
            progress: progress
        ).run()

        return mainRemover?.usedStrategies ?? []
    }

    private static func videoComposition(
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        timeRange: CMTimeRange,
        targetPixelSize: CGSize,
        frameDuration: CMTime,
        colorProperties: [String: String],
        crop: CGRect? = nil
    ) -> AVMutableVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let fullSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        // With a crop, only that part of the upright picture is fitted to
        // the target; the rest falls outside the render size.
        let visible = crop.map {
            CGRect(x: $0.minX * fullSize.width, y: $0.minY * fullSize.height, width: $0.width * fullSize.width, height: $0.height * fullSize.height)
        } ?? CGRect(origin: .zero, size: fullSize)
        let orientedSize = visible.size
        let scale = min(targetPixelSize.width / orientedSize.width, targetPixelSize.height / orientedSize.height)
        let translated = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX - visible.minX, y: -transformedRect.minY - visible.minY)
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

/// Reads decoded frames, applies the loop dissolve on the GPU and appends
/// them to the writer, driven by the writer's readiness callback.
///
/// Like `TranscodeSession`, it is the single owner of its AVFoundation
/// objects and only touches them on its private queue once `run()` started.
private final class EditSession: @unchecked Sendable {
    private let mainReader: AVAssetReader
    private let mainOutput: AVAssetReaderOutput
    private let headReader: AVAssetReader?
    private let headOutput: AVAssetReaderOutput?
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let processor: PlaneProcessor?
    private let mainRemover: WatermarkRemover?
    private let headRemover: WatermarkRemover?
    private let dissolveStart: Double
    private let dissolveDuration: Double
    private let frameDuration: CMTime
    private let outputDuration: Double
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "com.yurisantos.wallpaper.edit", qos: .utility)

    private let lock = NSLock()
    private var isCancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var firstTime: CMTime?
    private var lastOutputTime: CMTime = .zero
    private var lastReportedPercent = -1

    init(
        mainReader: AVAssetReader,
        mainOutput: AVAssetReaderOutput,
        headReader: AVAssetReader?,
        headOutput: AVAssetReaderOutput?,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        processor: PlaneProcessor?,
        mainRemover: WatermarkRemover? = nil,
        headRemover: WatermarkRemover? = nil,
        dissolveStart: Double,
        dissolveDuration: Double,
        frameDuration: CMTime,
        outputDuration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.mainRemover = mainRemover
        self.headRemover = headRemover
        self.mainReader = mainReader
        self.mainOutput = mainOutput
        self.headReader = headReader
        self.headOutput = headOutput
        self.writer = writer
        self.writerInput = writerInput
        self.adaptor = adaptor
        self.processor = processor
        self.dissolveStart = dissolveStart
        self.dissolveDuration = dissolveDuration
        self.frameDuration = frameDuration
        self.outputDuration = outputDuration
        self.progress = progress
    }

    func run() async throws {
        try Task.checkCancellation()

        guard mainReader.startReading() else {
            throw mainReader.error ?? VideoOptimizationError.readerSetupFailed
        }
        if let headReader, !headReader.startReading() {
            mainReader.cancelReading()
            throw headReader.error ?? VideoOptimizationError.readerSetupFailed
        }
        guard writer.startWriting() else {
            cancelReaders()
            throw writer.error ?? VideoOptimizationError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)

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
                queue.async { [self] in
                    if lock.withLock({ isCancelled }) {
                        finish(with: CancellationError())
                    }
                }
            }
        } catch {
            cancelReaders()
            queue.sync {}
            writer.cancelWriting()
            throw error
        }

        guard mainReader.status == .completed else {
            headReader?.cancelReading()
            writer.cancelWriting()
            throw mainReader.error ?? VideoOptimizationError.readerFailed
        }
        headReader?.cancelReading()

        // The last frame lasts one frame; without this the file would end
        // on its presentation time and the loop would be one frame short.
        writer.endSession(atSourceTime: lastOutputTime + frameDuration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? VideoOptimizationError.writerFailed
        }
    }

    private func cancelReaders() {
        mainReader.cancelReading()
        headReader?.cancelReading()
    }

    private func drain() {
        while writerInput.isReadyForMoreMediaData {
            if lock.withLock({ isCancelled }) {
                finish(with: CancellationError())
                return
            }

            let next: (frame: CVPixelBuffer, time: CMTime)?
            do {
                next = try nextFrame(from: mainOutput, remover: mainRemover)
            } catch {
                finish(with: error)
                return
            }
            guard let (frame, time) = next else {
                finish(with: nil)
                return
            }

            let first = firstTime ?? time
            firstTime = first
            let outputTime = time - first
            let seconds = outputTime.seconds

            var output = frame
            do {
                if let processor, let headOutput, dissolveDuration > 0, seconds >= dissolveStart - 0.0005,
                   let headFrame = try nextFrame(from: headOutput, remover: headRemover)?.frame {
                    // Even steps from the last untouched frame to the first
                    // frame of the next pass of the loop.
                    let step = frameDuration.seconds
                    let weight = (seconds - dissolveStart + step) / (dissolveDuration + step)
                    output = try processor.crossfade(frame, headFrame, weight: Float(weight))
                }
            } catch {
                finish(with: error)
                return
            }

            guard adaptor.append(output, withPresentationTime: outputTime) else {
                finish(with: writer.error ?? VideoOptimizationError.writerAppendFailed)
                return
            }
            lastOutputTime = outputTime
            report(seconds)
        }
    }

    /// The next frame of a stream, with logos removed when a remover is
    /// attached. The remover looks a few frames ahead, so input is fed to it
    /// until it can release a frame.
    private func nextFrame(
        from output: AVAssetReaderOutput, remover: WatermarkRemover?
    ) throws -> (frame: CVPixelBuffer, time: CMTime)? {
        guard let remover else {
            while let sample = output.copyNextSampleBuffer() {
                if let frame = CMSampleBufferGetImageBuffer(sample) {
                    return (frame, CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
            return nil
        }

        while true {
            if let ready = try remover.pop() { return ready }
            guard let sample = output.copyNextSampleBuffer() else {
                remover.finish()
                return try remover.pop()
            }
            if let frame = CMSampleBufferGetImageBuffer(sample) {
                remover.push(frame, time: CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
    }

    private func report(_ seconds: Double) {
        guard outputDuration > 0 else { return }
        let fraction = min(max(seconds / outputDuration, 0), 0.99)
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
    case processingUnavailable

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
        case .processingUnavailable:
            return String(localized: "This Mac cannot process the edits: no graphics device is available.")
        }
    }
}
