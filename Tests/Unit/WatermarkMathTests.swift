import XCTest
@testable import WallSync

/// Synthetic pictures for the logo-removal tests.
enum Synthetic {
    /// A smooth but non-trivial scene that can be panned: sums of sines.
    static func scene(width: Int, height: Int, offsetX: Double = 0, offsetY: Double = 0, textured: Bool = true) -> PlaneImage {
        var image = PlaneImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) + offsetX, v = Double(y) + offsetY
                var value = 0.5 + 0.22 * sin(u / 37) + 0.16 * cos(v / 29) + 0.08 * sin((u + v) / 53)
                if textured { value += 0.04 * sin(u / 5.1) * cos(v / 6.3) }
                image[x, y] = Float(min(max(value, 0.02), 0.98))
            }
        }
        return image
    }

    /// 1 inside the "logo" (a ring with a bar through it), 0 outside.
    static func logoShape(in rect: PixelRect) -> (Int, Int) -> Bool {
        { x, y in
            guard rect.contains(x, y) else { return false }
            let cx = Double(rect.x) + Double(rect.width) / 2, cy = Double(rect.y) + Double(rect.height) / 2
            let radius = Double(min(rect.width, rect.height)) / 2 - 2
            let distance = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
            return (distance < radius && distance > radius * 0.55) || abs(Double(y) - cy) < 2
        }
    }

    static func stamped(_ image: PlaneImage, rect: PixelRect, opacity: Float, color: Float = 0.95) -> PlaneImage {
        var output = image
        let shape = logoShape(in: rect)
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX where shape(x, y) {
                output[x, y] = (1 - opacity) * image[x, y] + opacity * color
            }
        }
        return output
    }

    /// Peak signal-to-noise ratio inside `rect`, in dB, for values 0 … 1.
    static func psnr(_ a: PlaneImage, _ b: PlaneImage, in rect: PixelRect) -> Double {
        var total = 0.0
        for y in rect.y..<rect.maxY {
            for x in rect.x..<rect.maxX {
                let difference = Double(a[x, y] - b[x, y])
                total += difference * difference
            }
        }
        let mse = total / Double(rect.width * rect.height)
        return mse <= 1e-12 ? 120 : 10 * log10(1 / mse)
    }
}

final class WatermarkPlannerTests: XCTestCase {
    func testReframeKeepsProportionsAndExcludesACornerLogo() throws {
        let logo = CGRect(x: 0.9, y: 0.93, width: 0.08, height: 0.05) // bottom right
        let reframe = try XCTUnwrap(WatermarkPlanner.reframe(excluding: [logo]))
        XCTAssertEqual(reframe.crop.width, reframe.crop.height, "same proportions as the video")
        XCTAssertFalse(reframe.crop.intersects(logo))
        XCTAssertEqual(reframe.crop.origin, .zero, "anchored to the opposite corner")
        XCTAssertEqual(reframe.crop.width, 0.93, accuracy: 1e-9, "only as much as needed is cut")
        XCTAssertEqual(reframe.areaLoss, 1 - 0.93 * 0.93, accuracy: 1e-9)
    }

    func testReframeIsNotOfferedWhenItCostsTooMuch() {
        XCTAssertNil(WatermarkPlanner.reframe(excluding: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)]), "a logo in the middle")
        XCTAssertNil(WatermarkPlanner.reframe(excluding: []))
        // Two logos in opposite corners cannot both be cut cheaply.
        XCTAssertNil(WatermarkPlanner.reframe(excluding: [
            CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.05), CGRect(x: 0.88, y: 0.93, width: 0.1, height: 0.05)
        ]))
    }

    func testRegionAlreadyCutOffByFillingTheScreen() {
        let video = CGSize(width: 1920, height: 1080)
        let edgeLogo = CGRect(x: 0.01, y: 0.4, width: 0.05, height: 0.1) // far left
        // A 4:3 display filling the screen cuts 12.5% off each side.
        XCTAssertTrue(WatermarkPlanner.isCroppedOut(region: edgeLogo, videoSize: video, displaySizes: [CGSize(width: 1600, height: 1200)]))
        XCTAssertFalse(WatermarkPlanner.isCroppedOut(region: edgeLogo, videoSize: video, displaySizes: [CGSize(width: 1920, height: 1080)]))
        XCTAssertFalse(
            WatermarkPlanner.isCroppedOut(region: edgeLogo, videoSize: video, displaySizes: [CGSize(width: 1600, height: 1200), CGSize(width: 1920, height: 1080)]),
            "it has to be hidden on every display"
        )
    }

    func testStrategyFollowsTheAnalysis() {
        XCTAssertEqual(WatermarkPlanner.strategy(for: .init(translucentFraction: 0.95, markedFraction: 0.3)), .unblend)
        XCTAssertEqual(WatermarkPlanner.strategy(for: .init(translucentFraction: 0.2, markedFraction: 0.3)), .spatial)
        XCTAssertEqual(WatermarkPlanner.strategy(for: .init(translucentFraction: 1, markedFraction: 0)), .spatial, "nothing measurable")
    }
}

final class WatermarkMathTests: XCTestCase {
    private let rect = PixelRect(x: 60, y: 40, width: 48, height: 28)

    func testSpatialFillMeetsItsSurroundings() {
        let image = Synthetic.scene(width: 160, height: 100, textured: false)
        let fill = SpatialFill.fill(image, rect: rect)

        var filled = image
        for row in 0..<rect.height {
            for column in 0..<rect.width { filled[rect.x + column, rect.y + row] = fill[row * rect.width + column] }
        }
        let psnr = Synthetic.psnr(filled, image, in: rect)
        XCTAssertGreaterThan(psnr, 30, "smooth background reconstructed from the border: \(psnr) dB")

        // No seam: the first row inside is close to the row just outside.
        for column in stride(from: 0, to: rect.width, by: 6) {
            XCTAssertEqual(fill[column], image[rect.x + column, rect.y - 1], accuracy: 0.03)
        }
    }

    func testSpatialFillOfAFlatPictureIsExactAndWorksAtTheImageEdge() {
        let flat = PlaneImage(width: 80, height: 60, fill: 0.4)
        let corner = PixelRect(x: 60, y: 44, width: 20, height: 16) // touches two edges
        XCTAssertTrue(SpatialFill.fill(flat, rect: corner).allSatisfy { abs($0 - 0.4) < 1e-5 })
        XCTAssertLessThanOrEqual(SpatialFill.samples(of: flat, around: PixelRect(x: 0, y: 0, width: 800, height: 400)).count, SpatialFill.maximumSamples + 4)
    }

    func testBlendEstimatorRecoversOpacityColourAndOutline() {
        // 24 frames of a panning scene, with a 40% white logo.
        let opacity: Float = 0.4, color: Float = 0.95
        let shape = Synthetic.logoShape(in: rect)
        var observed: [[Float]] = [], background: [[Float]] = [], truth: [PlaneImage] = [], stampedFrames: [PlaneImage] = []
        for frame in 0..<24 {
            let scene = Synthetic.scene(width: 160, height: 100, offsetX: Double(frame) * 23, offsetY: Double(frame) * 11, textured: false)
            let stamped = Synthetic.stamped(scene, rect: rect, opacity: opacity, color: color)
            truth.append(scene)
            stampedFrames.append(stamped)
            observed.append((0..<rect.height).flatMap { row in (0..<rect.width).map { stamped[rect.x + $0, rect.y + row] } })
            background.append(SpatialFill.fill(stamped, rect: rect))
        }

        let result = BlendEstimator.estimate(observed: observed, background: background)
        XCTAssertGreaterThan(result.analysis.translucentFraction, 0.9)
        XCTAssertEqual(WatermarkPlanner.strategy(for: result.analysis), .unblend)

        var inside: [Float] = [], interceptInside: [Float] = [], outsideUntouched = 0, outside = 0
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let index = row * rect.width + column
                if shape(rect.x + column, rect.y + row) {
                    inside.append(result.slope[index])
                    interceptInside.append(result.intercept[index])
                } else {
                    outside += 1
                    if result.slope[index] == 1 && result.intercept[index] == 0 { outsideUntouched += 1 }
                }
            }
        }
        let meanSlope = inside.reduce(0, +) / Float(inside.count)
        let meanIntercept = interceptInside.reduce(0, +) / Float(interceptInside.count)
        XCTAssertEqual(meanSlope, 1 - opacity, accuracy: 0.06, "slope is 1 - opacity")
        XCTAssertEqual(meanIntercept, opacity * color, accuracy: 0.05, "intercept is opacity x colour")
        XCTAssertGreaterThan(Double(outsideUntouched) / Double(outside), 0.9, "pixels outside the logo's outline are left alone")

        // Un-mixing a frame gives the original back.
        var recovered = stampedFrames[5]
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let index = row * rect.width + column
                if result.slope[index] >= BlendEstimator.minimumSlope {
                    recovered[rect.x + column, rect.y + row] = (stampedFrames[5][rect.x + column, rect.y + row] - result.intercept[index]) / result.slope[index]
                }
            }
        }
        let before = Synthetic.psnr(stampedFrames[5], truth[5], in: rect)
        let after = Synthetic.psnr(recovered, truth[5], in: rect)
        XCTAssertGreaterThan(after, 34, "after un-mixing: \(after) dB (before: \(before) dB)")
        XCTAssertGreaterThan(after, before + 12)
    }

    func testBlendEstimatorRejectsOpaqueMarksAndStaticBackgrounds() {
        var observed: [[Float]] = [], background: [[Float]] = []
        for frame in 0..<24 {
            let scene = Synthetic.scene(width: 160, height: 100, offsetX: Double(frame) * 23, textured: false)
            let stamped = Synthetic.stamped(scene, rect: rect, opacity: 1)
            observed.append((0..<rect.height).flatMap { row in (0..<rect.width).map { stamped[rect.x + $0, rect.y + row] } })
            background.append(SpatialFill.fill(stamped, rect: rect))
        }
        let opaque = BlendEstimator.estimate(observed: observed, background: background)
        XCTAssertLessThan(opaque.analysis.translucentFraction, 0.35, "an opaque mark hides the background: nothing to un-mix")
        XCTAssertEqual(WatermarkPlanner.strategy(for: opaque.analysis), .spatial)

        // Translucent, but the background never changes: the mix cannot be
        // measured, and that is reported rather than guessed.
        let still = Synthetic.stamped(Synthetic.scene(width: 160, height: 100, textured: false), rect: rect, opacity: 0.4)
        let row = (0..<rect.height).flatMap { row in (0..<rect.width).map { still[rect.x + $0, rect.y + row] } }
        let fixed = BlendEstimator.estimate(observed: Array(repeating: row, count: 24), background: Array(repeating: SpatialFill.fill(still, rect: rect), count: 24))
        XCTAssertEqual(WatermarkPlanner.strategy(for: fixed.analysis), .spatial)
    }

    func testCoarseMotionFindsThePanAndIgnoresTheMark() {
        let a = Synthetic.stamped(Synthetic.scene(width: 160, height: 90), rect: PixelRect(x: 120, y: 60, width: 30, height: 20), opacity: 1)
        // The scene moves 5 px right and 3 px up; the logo stays put.
        let b = Synthetic.stamped(Synthetic.scene(width: 160, height: 90, offsetX: -5, offsetY: 3), rect: PixelRect(x: 120, y: 60, width: 30, height: 20), opacity: 1)
        let shift = MotionSearch.coarse(from: a, to: b, radius: 12, exclude: [PixelRect(x: 120, y: 60, width: 30, height: 20)])
        XCTAssertEqual(shift.dx, 5, accuracy: 0.3)
        XCTAssertEqual(shift.dy, -3, accuracy: 0.3)
        XCTAssertLessThan(shift.error, 0.01)

        let none = MotionSearch.coarse(from: a, to: a, radius: 12)
        XCTAssertEqual(none.dx, 0, accuracy: 0.1)
        XCTAssertEqual(none.dy, 0, accuracy: 0.1)
    }

    func testRefineLocksOntoTheExactShiftAroundTheMark() throws {
        let mark = PixelRect(x: 70, y: 40, width: 24, height: 16)
        let current = Synthetic.stamped(Synthetic.scene(width: 180, height: 100), rect: mark, opacity: 1)
        let candidate = Synthetic.stamped(Synthetic.scene(width: 180, height: 100, offsetX: -37, offsetY: 2), rect: mark, opacity: 1)

        let refined = try XCTUnwrap(MotionSearch.refine(current: current, candidate: candidate, rect: mark, around: (35, 0), radius: 4))
        XCTAssertEqual(refined.dx, 37)
        XCTAssertEqual(refined.dy, -2)
        XCTAssertLessThan(refined.error, 0.005)
        XCTAssertTrue(MotionSearch.uncovers(rect: mark, dx: refined.dx, dy: refined.dy))
        XCTAssertFalse(MotionSearch.uncovers(rect: mark, dx: 20, dy: 3), "still partly behind the mark")
    }

    func testDetectorFindsAFixedLogoInAMovingScene() throws {
        let mark = PixelRect(x: 124, y: 70, width: 26, height: 14)
        let frames = (0..<16).map { frame in
            Synthetic.stamped(
                Synthetic.scene(width: 160, height: 90, offsetX: Double(frame) * 31, offsetY: Double(frame) * 17),
                rect: mark, opacity: frame % 2 == 0 ? 0.5 : 0.5
            )
        }
        let proposal = WatermarkDetector.detect(frames: frames)
        let region = try XCTUnwrap(proposal.regions.first, "a region is proposed")
        let expected = CGRect(x: 124.0 / 160, y: 70.0 / 90, width: 26.0 / 160, height: 14.0 / 90)
        let overlap = region.intersection(expected)
        XCTAssertGreaterThan(overlap.width * overlap.height, 0.8 * expected.width * expected.height, "covers the logo")
        XCTAssertLessThan(region.width * region.height, 6 * expected.width * expected.height, "without swallowing the picture")
    }

    func testDetectorStaysSilentWithoutALogoOrWithoutMotion() {
        let moving = (0..<16).map { Synthetic.scene(width: 160, height: 90, offsetX: Double($0) * 31, offsetY: Double($0) * 17) }
        XCTAssertTrue(WatermarkDetector.detect(frames: moving).regions.isEmpty, "no logo: no suggestion")

        let still = Array(repeating: Synthetic.stamped(Synthetic.scene(width: 160, height: 90), rect: PixelRect(x: 20, y: 20, width: 30, height: 20), opacity: 1), count: 16)
        XCTAssertTrue(WatermarkDetector.detect(frames: still).regions.isEmpty, "a still scene cannot tell a logo from the picture")
    }
}
