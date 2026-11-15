import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
@testable import WallSync

/// Helpers to build and inspect frames and clips with known content.
enum FrameFactory {
    static func buffer(
        width: Int, height: Int, tenBit: Bool,
        luma: (Int, Int) -> Int,
        chroma: (Int, Int) -> (Int, Int) = { _, _ in (-1, -1) }
    ) -> CVPixelBuffer {
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format,
            PlaneProcessor.bufferAttributes(pixelFormat: format) as CFDictionary, &created
        )
        let buffer = created!
        let neutral = tenBit ? 512 : 128
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for y in 0..<planeHeight {
                let row = base + y * rowBytes
                for x in 0..<planeWidth {
                    let values: [Int]
                    if plane == 0 {
                        values = [luma(x, y)]
                    } else {
                        let pair = chroma(x, y)
                        values = [pair.0 < 0 ? neutral : pair.0, pair.1 < 0 ? neutral : pair.1]
                    }
                    for (index, value) in values.enumerated() {
                        if tenBit {
                            row.storeBytes(of: UInt16(value << 6), toByteOffset: (x * values.count + index) * 2, as: UInt16.self)
                        } else {
                            row.storeBytes(of: UInt8(value), toByteOffset: x * values.count + index, as: UInt8.self)
                        }
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Luma samples at the buffer's bit depth (8-bit: 0…255, 10-bit: 0…1023).
    static func luma(of buffer: CVPixelBuffer) -> [[Int]] { samples(of: buffer, plane: 0, component: 0) }

    static func samples(of buffer: CVPixelBuffer, plane: Int, component: Int) -> [[Int]] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let components = plane == 0 ? 1 : 2
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        return (0..<CVPixelBufferGetHeightOfPlane(buffer, plane)).map { y in
            (0..<CVPixelBufferGetWidthOfPlane(buffer, plane)).map { x in
                tenBit
                    ? Int((base + y * rowBytes).load(fromByteOffset: (x * components + component) * 2, as: UInt16.self)) >> 6
                    : Int((base + y * rowBytes).load(fromByteOffset: x * components + component, as: UInt8.self))
            }
        }
    }

    static func meanLuma(of buffer: CVPixelBuffer) -> Double {
        let rows = luma(of: buffer)
        let total = rows.reduce(0) { $0 + $1.reduce(0, +) }
        return Double(total) / Double(max(1, rows.count * (rows.first?.count ?? 1)))
    }

    /// Writes a clip whose frames come from `frame(index)`.
    static func writeClip(
        to url: URL, frameCount: Int, frameRate: Int32 = 30, keyframeInterval: Int? = nil,
        codec: AVVideoCodecType = .h264, includeAudio: Bool = false,
        frame: (Int) -> CVPixelBuffer
    ) async throws {
        let first = frame(0)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: CVPixelBufferGetWidth(first),
            AVVideoHeightKey: CVPixelBufferGetHeight(first)
        ]
        var compression: [String: Any] = [AVVideoAllowFrameReorderingKey: false]
        if let keyframeInterval { compression[AVVideoMaxKeyFrameIntervalKey] = keyframeInterval }
        if codec == .h264 { compression[AVVideoAverageBitRateKey] = 6_000_000 }
        if codec == .hevc, CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        settings[AVVideoCompressionPropertiesKey] = compression

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SyntheticVideo.Failure.writerFailed }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(index == 0 ? first : frame(index), withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: frameRate))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SyntheticVideo.Failure.writerFailed }
    }

    /// Decodes every frame of a file to 8-bit biplanar buffers.
    static func decodeFrames(of url: URL, tenBit: Bool = false) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        reader.add(output)
        reader.startReading()
        var frames: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(buffer) }
        }
        return frames
    }
}

final class PlaneProcessorTests: XCTestCase {
    private func processor() throws -> PlaneProcessor {
        try XCTUnwrap(PlaneProcessor(), "no Metal device")
    }

    override func setUpWithError() throws {
        try XCTSkipIf(PlaneProcessor() == nil, "no Metal device on this machine")
    }

    func testCrossfadeInterpolatesTenBitSamplesOnTheTenBitGrid() throws {
        let a = FrameFactory.buffer(width: 64, height: 32, tenBit: true, luma: { x, _ in 100 + x }, chroma: { _, _ in (400, 600) })
        let b = FrameFactory.buffer(width: 64, height: 32, tenBit: true, luma: { x, _ in 900 - x }, chroma: { _, _ in (600, 400) })
        let output = try processor().crossfade(a, b, weight: 0.25)

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "still 10-bit")
        let luma = FrameFactory.luma(of: output)
        for x in [0, 13, 63] {
            let expected = Int((0.75 * Double(100 + x) + 0.25 * Double(900 - x)).rounded())
            XCTAssertEqual(luma[5][x], expected, accuracy: 1)
        }
        XCTAssertEqual(FrameFactory.samples(of: output, plane: 1, component: 0)[3][3], 450, accuracy: 1)
        XCTAssertEqual(FrameFactory.samples(of: output, plane: 1, component: 1)[3][3], 550, accuracy: 1)

        // The raw storage has nothing below the 10-bit grid.
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let raw = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.load(fromByteOffset: 26, as: UInt16.self)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        XCTAssertEqual(raw & 0x3F, 0)
    }

    func testCrossfadeOfEqualFramesChangesNothing() throws {
        // No brightness shift in the middle of a dissolve between like frames.
        let a = FrameFactory.buffer(width: 32, height: 16, tenBit: true, luma: { x, y in 64 + x * 20 + y })
        let b = FrameFactory.buffer(width: 32, height: 16, tenBit: true, luma: { x, y in 64 + x * 20 + y })
        for weight in [Float(0), 0.37, 0.5, 1] {
            XCTAssertEqual(FrameFactory.luma(of: try processor().crossfade(a, b, weight: weight)), FrameFactory.luma(of: a))
        }
    }

    func testCrossfadeEndpointsAndEightBit() throws {
        let a = FrameFactory.buffer(width: 32, height: 16, tenBit: false, luma: { _, _ in 40 })
        let b = FrameFactory.buffer(width: 32, height: 16, tenBit: false, luma: { _, _ in 200 })
        XCTAssertEqual(FrameFactory.meanLuma(of: try processor().crossfade(a, b, weight: 0)), 40)
        XCTAssertEqual(FrameFactory.meanLuma(of: try processor().crossfade(a, b, weight: 1)), 200)
        XCTAssertEqual(FrameFactory.meanLuma(of: try processor().crossfade(a, b, weight: 0.5)), 120, accuracy: 1)
    }

    func testColorAttachmentsAreCarriedOver() throws {
        let a = FrameFactory.buffer(width: 32, height: 16, tenBit: true, luma: { _, _ in 300 })
        let b = FrameFactory.buffer(width: 32, height: 16, tenBit: true, luma: { _, _ in 500 })
        CVBufferSetAttachment(a, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(a, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        let output = try processor().crossfade(a, b, weight: 0.5)
        let transfer = CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, "HDR signalling is kept, never interpreted")
    }
}

/// The loop editor's output, produced by the real optimizer.
final class LoopEditIntegrationTests: XCTestCase {
    private var root: URL!
    private var storage: StorageLocations!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_MEDIA_TESTS"] != nil, "media pipeline tests disabled by SKIP_MEDIA_TESTS")
        root = try Fixture.temporaryDirectory()
        storage = StorageLocations(root: root)
        try storage.prepareDirectories()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 3 s at 30 fps; frame `i` is a flat grey of luma `40 + 2 i`, so every
    /// frame's position in the source can be read back from its brightness.
    private func makeRamp(keyframeInterval: Int? = 90, includeAudio: Bool = false) async throws -> URL {
        let url = root.appendingPathComponent("ramp-\(UUID().uuidString.prefix(6)).mp4")
        try await FrameFactory.writeClip(to: url, frameCount: 90, keyframeInterval: keyframeInterval) { index in
            FrameFactory.buffer(width: 320, height: 180, tenBit: false, luma: { _, _ in 40 + 2 * index })
        }
        return url
    }

    private func optimize(_ source: URL, recipe: EditRecipe, size: CGSize = CGSize(width: 320, height: 180)) async throws -> OptimizedPlaybackAsset {
        try await VideoAssetOptimizer(storage: storage).optimize(
            sourceURL: source, assetID: UUID(), maximumPixelSize: size, quality: .efficiency, recipe: recipe
        )
    }

    func testEmptyRecipeIsCopiedWithoutReencoding() async throws {
        let rendition = try await optimize(try await makeRamp(), recipe: .empty)
        XCTAssertTrue(rendition.isPassthrough, "an unedited, suitable video is never re-encoded")
        XCTAssertEqual(rendition.recipe, .empty)
        XCTAssertEqual(rendition.duration, 3, accuracy: 0.05)
    }

    func testTrimWithCrossfadeHasTheRightDurationAndAContinuousLoopPoint() async throws {
        let source = try await makeRamp()
        var recipe = EditRecipe()
        recipe.trim = .init(start: 0.5, end: 2.5)
        recipe.loopCrossfade = 0.5

        let rendition = try await optimize(source, recipe: recipe)
        XCTAssertFalse(rendition.isPassthrough)
        XCTAssertEqual(rendition.recipe, recipe)
        XCTAssertEqual(rendition.duration, 1.5, accuracy: 1.0 / 30 + 0.005, "(end - start) - crossfade")

        let url = storage.url(forRelativePath: rendition.relativePath)
        let output = AVURLAsset(url: url)
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "no audio")

        let luma = try await FrameFactory.decodeFrames(of: url).map(FrameFactory.meanLuma(of:))
        XCTAssertEqual(Double(luma.count), 45, accuracy: 1)

        // Starts at source frame 30 (0.5 s + 0.5 s crossfade): luma 100.
        XCTAssertEqual(luma[0], 100, accuracy: 4)
        // The body is the untouched ramp, two luma steps per frame.
        XCTAssertEqual(luma[20] - luma[10], 20, accuracy: 3)

        // The loop point: the last frame leads into the first one.
        let seam = abs(luma[luma.count - 1] - luma[0])
        XCTAssertLessThan(seam, 9, "last frame \(luma[luma.count - 1]) -> first frame \(luma[0])")
        // Without the dissolve the cut would be from frame 74 to frame 30.
        let uncutStep: Double = 2 * (74 - 30)
        XCTAssertGreaterThan(uncutStep, 80)

        // And no step anywhere in the loop is larger than the dissolve's own.
        var largest = 0.0
        for index in 0..<luma.count {
            largest = max(largest, abs(luma[(index + 1) % luma.count] - luma[index]))
        }
        XCTAssertLessThan(largest, 10, "largest frame-to-frame step in the loop")
    }

    func testTrimWithoutCrossfadeKeepsExactlyTheSelection() async throws {
        let source = try await makeRamp()
        var recipe = EditRecipe()
        recipe.trim = .init(start: 1.2, end: 2.2) // frames 36 ..< 66, between keyframes

        let rendition = try await optimize(source, recipe: recipe)
        XCTAssertFalse(rendition.isPassthrough, "the selection does not start on a keyframe")
        XCTAssertEqual(rendition.duration, 1, accuracy: 0.05)
        let luma = try await FrameFactory.decodeFrames(of: storage.url(forRelativePath: rendition.relativePath)).map(FrameFactory.meanLuma(of:))
        XCTAssertEqual(luma.first ?? 0, 40 + 2 * 36, accuracy: 5)
        XCTAssertEqual(luma.last ?? 0, 40 + 2 * 65, accuracy: 5)
    }

    func testTrimOnKeyframesIsCutWithoutReencoding() async throws {
        let source = try await makeRamp(keyframeInterval: 15)
        var recipe = EditRecipe()
        recipe.trim = .init(start: 1, end: 2) // frames 30 ..< 60, both keyframes

        let rendition = try await optimize(source, recipe: recipe)
        XCTAssertTrue(rendition.isPassthrough, "keyframe-aligned selections are copied")
        XCTAssertEqual(rendition.recipe, recipe)
        XCTAssertEqual(rendition.duration, 1, accuracy: 0.05)

        let luma = try await FrameFactory.decodeFrames(of: storage.url(forRelativePath: rendition.relativePath)).map(FrameFactory.meanLuma(of:))
        XCTAssertEqual(Double(luma.count), 30, accuracy: 1)
        XCTAssertEqual(luma.first ?? 0, 100, accuracy: 4)
    }

    func testCropShowsOnlyTheChosenPart() async throws {
        let url = root.appendingPathComponent("split.mp4")
        try await FrameFactory.writeClip(to: url, frameCount: 30) { _ in
            FrameFactory.buffer(width: 320, height: 180, tenBit: false, luma: { x, _ in x < 160 ? 50 : 200 })
        }
        var recipe = EditRecipe()
        recipe.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let rendition = try await optimize(url, recipe: recipe)
        XCTAssertEqual(rendition.pixelSize, CGSize(width: 160, height: 180))
        let frames = try await FrameFactory.decodeFrames(of: storage.url(forRelativePath: rendition.relativePath))
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(FrameFactory.meanLuma(of: frame), 200, accuracy: 5, "only the right half is left")
    }

    func testCrossfadeKeepsTenBitHDR() async throws {
        let url = root.appendingPathComponent("hdr.mov")
        do {
            // 10-bit HLG; luma ramps with the frame index on the 10-bit scale.
            try await FrameFactory.writeClip(to: url, frameCount: 60, codec: .hevc) { index in
                let buffer = FrameFactory.buffer(width: 320, height: 180, tenBit: true, luma: { _, _ in 200 + 8 * index })
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                return buffer
            }
        } catch {
            throw XCTSkip("no 10-bit HEVC encoder on this machine: \(error)")
        }

        var recipe = EditRecipe()
        recipe.loopCrossfade = 0.5
        let rendition = try await optimize(url, recipe: recipe)

        XCTAssertEqual(rendition.bitDepth, 10, "the dissolve does not drop to 8 bits")
        XCTAssertTrue(rendition.isHDR, "HLG signalling survives the edit")
        XCTAssertEqual(rendition.duration, 1.5, accuracy: 0.05)

        let frames = try await FrameFactory.decodeFrames(of: storage.url(forRelativePath: rendition.relativePath), tenBit: true)
        let luma = frames.map(FrameFactory.meanLuma(of:))
        XCTAssertLessThan(abs((luma.last ?? 0) - (luma.first ?? 999)), 30, "continuous loop point on the 10-bit scale (one source frame is 8)")
        // Untouched body: one source frame per output frame, 8 levels apart,
        // so the levels in between are real 10-bit values.
        XCTAssertEqual(luma[11] - luma[10], 8, accuracy: 3)
    }
}
