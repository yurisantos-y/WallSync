import AVFoundation
import CoreVideo
import XCTest
@testable import WallSync

/// The quality bar of the logo remover, measured on synthetic video: a known
/// mark is put over a known scene, removed, and the result is compared with
/// the scene inside the marked area (PSNR, values 0 … 1) for every frame.
final class WatermarkRemovalQualityTests: XCTestCase {
    private let width = 320, height = 180
    private let region = CGRect(x: 0.72, y: 0.75, width: 0.125, height: 0.11)
    private var mark: PixelRect { WatermarkRemover.pixelRect(for: region, width: width, height: height, border: 0) }

    override func setUpWithError() throws {
        try XCTSkipIf(PlaneProcessor() == nil, "no Metal device on this machine")
    }

    private func buffer(_ image: PlaneImage, tenBit: Bool) -> CVPixelBuffer {
        let peak: Float = tenBit ? 1023 : 255
        return FrameFactory.buffer(width: image.width, height: image.height, tenBit: tenBit, luma: { x, y in
            Int((image[x, y] * peak).rounded())
        })
    }

    private func image(_ buffer: CVPixelBuffer) -> PlaneImage {
        let tenBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let rows = FrameFactory.luma(of: buffer)
        let peak: Float = tenBit ? 1023 : 255
        return PlaneImage(width: rows[0].count, height: rows.count, pixels: rows.flatMap { $0.map { Float($0) / peak } })
    }

    private struct Outcome {
        var strategy: WatermarkStrategy
        var worstPSNR: Double
        var meanPSNR: Double
        var inputPSNR: Double
        /// How much more the filled area changes from one frame to the next
        /// than the real scene does there (worst frame, mean over the area).
        /// Zero means the area is at least as steady as the scene itself;
        /// anything above is what would be seen as flicker.
        var flicker: Double
        var outsideChanged: Int
    }

    private func run(opacity: Float, panPerFrame: Double, tenBit: Bool = false, frames: Int = 24, textured: Bool = true) throws -> Outcome {
        let processor = try XCTUnwrap(PlaneProcessor())
        let truth = (0..<frames).map {
            Synthetic.scene(width: width, height: height, offsetX: Double($0) * panPerFrame, textured: textured)
        }
        let stamped = truth.map { Synthetic.stamped($0, rect: mark, opacity: opacity) }
        let inputs = stamped.map { buffer($0, tenBit: tenBit) }

        let plans = try WatermarkRemover.plan(regions: [region], samples: inputs, processor: processor)
        XCTAssertEqual(plans.count, 1)
        let remover = WatermarkRemover(processor: processor, plans: plans, frameRate: 30, frameBytes: width * height * 3)

        var outputs: [CVPixelBuffer] = []
        for (index, input) in inputs.enumerated() {
            remover.push(input, time: CMTime(value: CMTimeValue(index), timescale: 30))
            while let ready = try remover.pop() { outputs.append(ready.frame) }
        }
        remover.finish()
        while let ready = try remover.pop() { outputs.append(ready.frame) }
        XCTAssertEqual(outputs.count, frames, "every frame comes out, in order")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(outputs[0]), CVPixelBufferGetPixelFormatType(inputs[0]), "same bit depth out as in")

        let area = plans[0].rect
        var psnr: [Double] = [], filled: [[Float]] = [], real: [[Float]] = []
        var outsideChanged = 0
        for index in 0..<frames {
            let output = image(outputs[index])
            // The truth, quantized the way the input was.
            let reference = image(buffer(truth[index], tenBit: tenBit))
            psnr.append(Synthetic.psnr(output, reference, in: area))
            filled.append((area.y..<area.maxY).flatMap { y in (area.x..<area.maxX).map { output[$0, y] } })
            real.append((area.y..<area.maxY).flatMap { y in (area.x..<area.maxX).map { reference[$0, y] } })

            let input = image(inputs[index])
            for y in 0..<height {
                for x in 0..<width where !area.contains(x, y) && output[x, y] != input[x, y] {
                    outsideChanged += 1
                }
            }
        }
        var flicker = 0.0
        for index in 1..<frames {
            var outputChange: Float = 0, sceneChange: Float = 0
            for pixel in filled[index].indices {
                outputChange += abs(filled[index][pixel] - filled[index - 1][pixel])
                sceneChange += abs(real[index][pixel] - real[index - 1][pixel])
            }
            flicker = max(flicker, Double(max(0, outputChange - sceneChange)) / Double(filled[index].count))
        }

        let outcome = Outcome(
            strategy: remover.usedStrategies[0],
            worstPSNR: psnr.min() ?? 0,
            meanPSNR: psnr.reduce(0, +) / Double(psnr.count),
            inputPSNR: Synthetic.psnr(stamped[0], truth[0], in: area),
            flicker: flicker,
            outsideChanged: outsideChanged
        )
        print(String(
            format: "WATERMARK-QUALITY opacity=%.1f pan=%.0f tenBit=%d strategy=%@ input=%.1fdB worst=%.1fdB mean=%.1fdB flicker=%.4f",
            opacity, panPerFrame, tenBit ? 1 : 0, outcome.strategy.rawValue, outcome.inputPSNR, outcome.worstPSNR, outcome.meanPSNR, outcome.flicker
        ))
        return outcome
    }

    func testTranslucentMarkOverMovingBackgroundIsUnmixed() throws {
        let outcome = try run(opacity: 0.4, panPerFrame: 12)
        XCTAssertEqual(outcome.strategy, .unblend)
        XCTAssertGreaterThan(outcome.worstPSNR, 34, "worst frame")
        XCTAssertGreaterThan(outcome.worstPSNR, outcome.inputPSNR + 12)
        XCTAssertLessThan(outcome.flicker, 0.004)
        XCTAssertEqual(outcome.outsideChanged, 0, "the rest of the picture is bit for bit the input")
    }

    func testOpaqueMarkOverMovingBackgroundIsFilledFromNeighbouringFrames() throws {
        let outcome = try run(opacity: 1, panPerFrame: 12)
        XCTAssertEqual(outcome.strategy, .temporal)
        XCTAssertGreaterThan(outcome.meanPSNR, 36, "real content from other frames")
        // At the very end of this clip the scene behind the mark has left
        // the picture: those frames are filled from the surroundings, and
        // the change between the two fills is eased over several frames.
        XCTAssertGreaterThan(outcome.worstPSNR, 30)
        XCTAssertLessThan(outcome.flicker, 0.006, "no visible switch between kinds of fill")
        XCTAssertEqual(outcome.outsideChanged, 0)
    }

    func testOpaqueMarkOverStillBackgroundIsFilledFromItsSurroundings() throws {
        let outcome = try run(opacity: 1, panPerFrame: 0, textured: false)
        XCTAssertEqual(outcome.strategy, .spatial)
        XCTAssertGreaterThan(outcome.worstPSNR, 30)
        XCTAssertEqual(outcome.flicker, 0, accuracy: 1e-9, "a still scene gives the same fill in every frame")
        XCTAssertEqual(outcome.outsideChanged, 0)
    }

    func testTranslucentMarkOverStillBackgroundFallsBackToAFill() throws {
        // Nothing changes over time, so the mix cannot be measured; the
        // remover says so (strategy) instead of guessing.
        let outcome = try run(opacity: 0.4, panPerFrame: 0, textured: false)
        XCTAssertEqual(outcome.strategy, .spatial)
        XCTAssertGreaterThan(outcome.worstPSNR, 30)
        XCTAssertEqual(outcome.flicker, 0, accuracy: 1e-9)
    }

    func testTenBitFramesKeepTheirPrecision() throws {
        let unmixed = try run(opacity: 0.4, panPerFrame: 12, tenBit: true, frames: 18)
        XCTAssertEqual(unmixed.strategy, .unblend)
        XCTAssertGreaterThan(unmixed.worstPSNR, 34)
        XCTAssertEqual(unmixed.outsideChanged, 0)

        let filled = try run(opacity: 1, panPerFrame: 12, tenBit: true, frames: 18)
        XCTAssertEqual(filled.strategy, .temporal)
        XCTAssertGreaterThan(filled.meanPSNR, 36)
        XCTAssertGreaterThan(filled.worstPSNR, 30)
    }

    func testPixelRectIsEvenAndInsideTheFrame() {
        let rect = WatermarkRemover.pixelRect(for: CGRect(x: 0.901, y: 0.903, width: 0.2, height: 0.2), width: 641, height: 361)
        XCTAssertEqual(rect.x % 2, 0)
        XCTAssertEqual(rect.y % 2, 0)
        XCTAssertEqual(rect.width % 2, 0)
        XCTAssertEqual(rect.height % 2, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 640)
        XCTAssertLessThanOrEqual(rect.maxY, 360)
    }
}

/// The whole path: recipe -> optimizer -> file.
final class WatermarkOptimizerTests: XCTestCase {
    private var root: URL!
    private var storage: StorageLocations!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_MEDIA_TESTS"] != nil, "media pipeline tests disabled by SKIP_MEDIA_TESTS")
        try XCTSkipIf(PlaneProcessor() == nil, "no Metal device on this machine")
        root = try Fixture.temporaryDirectory()
        storage = StorageLocations(root: root)
        try storage.prepareDirectories()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRecipeWithARegionProducesACleanLoopingRendition() async throws {
        let width = 320, height = 180
        let region = CGRect(x: 0.72, y: 0.75, width: 0.125, height: 0.11)
        let mark = WatermarkRemover.pixelRect(for: region, width: width, height: height, border: 0)
        let source = root.appendingPathComponent("marked.mp4")
        try await FrameFactory.writeClip(to: source, frameCount: 60) { index in
            let scene = Synthetic.stamped(
                Synthetic.scene(width: width, height: height, offsetX: Double(index) * 12), rect: mark, opacity: 1
            )
            return FrameFactory.buffer(width: width, height: height, tenBit: false, luma: { x, y in 16 + Int(scene[x, y] * 219) })
        }

        var recipe = EditRecipe()
        recipe.watermarkRegions = [region]
        recipe.loopCrossfade = 0.5
        let rendition = try await VideoAssetOptimizer(storage: storage).optimize(
            sourceURL: source, assetID: UUID(), maximumPixelSize: CGSize(width: 320, height: 180), quality: .efficiency, recipe: recipe
        )

        XCTAssertEqual(rendition.recipe, recipe)
        XCTAssertEqual(rendition.watermarkStrategies, [WatermarkStrategy.temporal.rawValue], "the strategy used is recorded for the interface")
        XCTAssertEqual(rendition.duration, 1.5, accuracy: 0.05, "the loop edit still applies")

        // The logo was near-white; what is there now looks like the scene.
        let frames = try await FrameFactory.decodeFrames(of: storage.url(forRelativePath: rendition.relativePath))
        let middle = FrameFactory.luma(of: frames[frames.count / 2])
        var brightest = 0
        for y in mark.y..<mark.maxY {
            for x in mark.x..<mark.maxX { brightest = max(brightest, middle[y][x]) }
        }
        XCTAssertLessThan(brightest, 16 + Int(0.9 * 219), "no trace of the 95% white mark")
    }

    func testReframedVideoRecordsTheLosslessStrategy() async throws {
        let source = root.appendingPathComponent("plain.mp4")
        try await FrameFactory.writeClip(to: source, frameCount: 30) { index in
            FrameFactory.buffer(width: 320, height: 180, tenBit: false, luma: { _, _ in 60 + index })
        }
        var recipe = EditRecipe()
        recipe.crop = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
        let rendition = try await VideoAssetOptimizer(storage: storage).optimize(
            sourceURL: source, assetID: UUID(), maximumPixelSize: CGSize(width: 320, height: 180), quality: .efficiency, recipe: recipe
        )
        XCTAssertEqual(rendition.watermarkStrategies, [WatermarkStrategy.reframe.rawValue])
        XCTAssertEqual(rendition.pixelSize, CGSize(width: 288, height: 162))
    }

    func testEditorDetectionAndComparisonOnARealFile() async throws {
        let width = 320, height = 180
        let region = CGRect(x: 0.72, y: 0.75, width: 0.125, height: 0.11)
        let mark = WatermarkRemover.pixelRect(for: region, width: width, height: height, border: 0)
        let source = root.appendingPathComponent("logo.mp4")
        try await FrameFactory.writeClip(to: source, frameCount: 60) { index in
            let scene = Synthetic.stamped(
                Synthetic.scene(width: width, height: height, offsetX: Double(index) * 12, offsetY: Double(index) * 5), rect: mark, opacity: 1
            )
            return FrameFactory.buffer(width: width, height: height, tenBit: false, luma: { x, y in 16 + Int(scene[x, y] * 219) })
        }

        // "Suggest": the fixed logo is found without any hint.
        let detected = try await WatermarkPreviewer.detect(url: source)
        let found = try XCTUnwrap(detected.first, "a region is suggested")
        let overlap = found.intersection(region)
        XCTAssertGreaterThan(overlap.width * overlap.height, 0.7 * region.width * region.height, "the suggestion covers the logo")

        // "Compare": before still shows the mark, after does not.
        let result = try await WatermarkPreviewer.render(url: source, regions: [region], crop: nil, times: [1.25])
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(result.strategies.count, 1)
        let pair = try XCTUnwrap(result.pairs.first)
        XCTAssertEqual(pair.before.width, width)
        XCTAssertEqual(pair.after.width, pair.before.width)

        func brightness(_ image: CGImage) -> Double {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // The centre line of the logo (its horizontal bar).
            let row = mark.y + mark.height / 2
            var total = 0.0
            for x in mark.x..<mark.maxX { total += Double(bytes[(row * image.width + x) * 4 + 1]) }
            return total / Double(mark.width)
        }
        XCTAssertGreaterThan(brightness(pair.before), 215, "the mark's white bar is in the original")
        XCTAssertLessThan(brightness(pair.after), 190, "and gone after removal")
    }
}
