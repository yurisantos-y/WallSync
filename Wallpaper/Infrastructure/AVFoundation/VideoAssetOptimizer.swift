import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

actor VideoAssetOptimizer {
    private enum Constant {
        static let optimizedDirectoryName = "OptimizedVideos"
        static let targetFrameRate = 30.0
        static let bitsPerPixelFrame = 0.07
        static let minimumBitRate = 4_000_000.0
        static let maximumBitRate = 18_000_000.0
    }

    private let fileManager: FileManager
    private let capabilityInspector: VideoCapabilityInspector
    private let optimizedDirectory: URL

    init(
        fileManager: FileManager = .default,
        capabilityInspector: VideoCapabilityInspector = VideoCapabilityInspector()
    ) {
        self.fileManager = fileManager
        self.capabilityInspector = capabilityInspector
        let supportDirectory = try! fileManager.wallpaperApplicationSupportDirectory()
        self.optimizedDirectory = supportDirectory.appendingPathComponent(Constant.optimizedDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: optimizedDirectory.path) {
            try? fileManager.createDirectory(at: optimizedDirectory, withIntermediateDirectories: true)
        }
    }

    func optimize(
        sourceURL: URL,
        metadata: AssetInspectionResult,
        assetID: UUID,
        maximumPixelSize: CGSize
    ) async throws -> OptimizedPlaybackAsset {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw AssetMetadataError.noVideoTrack
        }

        let duration = try await sourceAsset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let targetFrameRate = min(max(metadata.frameRate, 1), Constant.targetFrameRate)
        let targetPixelSize = Self.targetPixelSize(
            sourcePixelSize: metadata.pixelSize,
            maximumPixelSize: maximumPixelSize
        )
        let targetBitRate = Self.targetBitRate(
            sourceBitRate: metadata.estimatedBitRate,
            pixelSize: targetPixelSize,
            frameRate: targetFrameRate
        )
        let codec = selectedCodec()
        let destination = optimizedDirectory.appendingPathComponent("\(assetID.uuidString).mp4")

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try await transcode(
            sourceAsset: sourceAsset,
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            duration: duration,
            destination: destination,
            targetPixelSize: targetPixelSize,
            targetFrameRate: targetFrameRate,
            targetBitRate: targetBitRate,
            codec: codec.avCodec
        )

        return OptimizedPlaybackAsset(
            relativePath: "\(Constant.optimizedDirectoryName)/\(assetID.uuidString).mp4",
            codecType: codec.assetCodecName,
            pixelSize: targetPixelSize,
            frameRate: targetFrameRate,
            estimatedBitRate: targetBitRate,
            duration: duration.seconds
        )
    }

    private func selectedCodec() -> (avCodec: AVVideoCodecType, assetCodecName: String) {
        if capabilityInspector.hardwareDecodeLikely(for: kCMVideoCodecType_HEVC) {
            return (.hevc, "HEVC")
        }

        return (.h264, "H264")
    }

    private func transcode(
        sourceAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: CMTime,
        destination: URL,
        targetPixelSize: CGSize,
        targetFrameRate: Double,
        targetBitRate: Double,
        codec: AVVideoCodecType
    ) async throws {
        let reader = try AVAssetReader(asset: sourceAsset)
        let videoComposition = Self.videoComposition(
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            duration: duration,
            targetPixelSize: targetPixelSize,
            targetFrameRate: targetFrameRate
        )
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoOptimizationError.readerSetupFailed
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(targetPixelSize.width),
                AVVideoHeightKey: Int(targetPixelSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(targetBitRate),
                    AVVideoExpectedSourceFrameRateKey: Int(targetFrameRate.rounded()),
                    AVVideoMaxKeyFrameIntervalKey: Int(targetFrameRate.rounded() * 2)
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw VideoOptimizationError.writerSetupFailed
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? VideoOptimizationError.readerSetupFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? VideoOptimizationError.writerSetupFailed
        }

        writer.startSession(atSourceTime: .zero)

        while reader.status == .reading {
            try Task.checkCancellation()

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }

            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }

            guard writerInput.append(sampleBuffer) else {
                reader.cancelReading()
                throw writer.error ?? VideoOptimizationError.writerAppendFailed
            }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? VideoOptimizationError.readerFailed
        }

        writerInput.markAsFinished()
        try await finishWriting(writer)

        guard writer.status == .completed else {
            throw writer.error ?? VideoOptimizationError.writerFailed
        }
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws {
        let writerBox = AVAssetWriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if let error = writerBox.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func videoComposition(
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: CMTime,
        targetPixelSize: CGSize,
        targetFrameRate: Double
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
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = targetPixelSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(targetFrameRate.rounded()))))
        composition.instructions = [instruction]
        return composition
    }

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

    static func targetBitRate(sourceBitRate: Double, pixelSize: CGSize, frameRate: Double) -> Double {
        let calculated = pixelSize.width * pixelSize.height * frameRate * Constant.bitsPerPixelFrame
        let clamped = min(max(calculated, Constant.minimumBitRate), Constant.maximumBitRate)

        guard sourceBitRate > 0 else {
            return clamped
        }

        return min(sourceBitRate, clamped)
    }

    private static func evenDimension(_ value: CGFloat) -> CGFloat {
        max(2, CGFloat(Int(value.rounded(.down)) / 2 * 2))
    }
}

private final class AVAssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
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
            return "Nao foi possivel preparar a leitura do video."
        case .writerSetupFailed:
            return "Nao foi possivel preparar o arquivo otimizado."
        case .writerAppendFailed:
            return "Nao foi possivel gravar um frame do video otimizado."
        case .readerFailed:
            return "A leitura do video original falhou."
        case .writerFailed:
            return "A gravacao do video otimizado falhou."
        }
    }
}
