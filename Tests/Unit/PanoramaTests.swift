import XCTest
@testable import WallSync

final class PanoramaLayoutTests: XCTestCase {
    private func display(_ id: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> PanoramaLayout.Display {
        .init(id: id, frame: CGRect(x: x, y: y, width: width, height: height))
    }

    private func assertRect(_ actual: CGRect?, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("missing crop", file: file, line: line) }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, "x", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, "y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, "height", file: file, line: line)
    }

    /// Every display must show the picture at the same scale, with the
    /// proportions of its own frame, and neighbours must meet exactly.
    private func assertContinuous(_ displays: [PanoramaLayout.Display], _ crops: [String: CGRect], video: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        var scales: [CGFloat] = []
        for display in displays {
            guard let crop = crops[display.id] else { return XCTFail("missing \(display.id)", file: file, line: line) }
            scales.append(display.frame.width / (crop.width * video.width))
            scales.append(display.frame.height / (crop.height * video.height))
            XCTAssertGreaterThanOrEqual(crop.minX, -1e-9, file: file, line: line)
            XCTAssertGreaterThanOrEqual(crop.minY, -1e-9, file: file, line: line)
            XCTAssertLessThanOrEqual(crop.maxX, 1 + 1e-9, file: file, line: line)
            XCTAssertLessThanOrEqual(crop.maxY, 1 + 1e-9, file: file, line: line)
        }
        for scale in scales {
            XCTAssertEqual(scale, scales[0], accuracy: 1e-6, "one scale for the whole picture", file: file, line: line)
        }
        // A point of the desktop maps to one point of the video whichever
        // display it is seen through: check the offsets between displays.
        guard let first = displays.first, let firstCrop = crops[first.id] else { return }
        for display in displays.dropFirst() {
            let crop = crops[display.id]!
            XCTAssertEqual((crop.minX - firstCrop.minX) * video.width * scales[0], display.frame.minX - first.frame.minX, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual((crop.minY - firstCrop.minY) * video.height * scales[0], first.frame.maxY - display.frame.maxY, accuracy: 1e-6, file: file, line: line)
        }
    }

    func testSideBySideDisplaysSplitTheVideoInHalves() {
        let displays = [display("left", 0, 0, 1920, 1080), display("right", 1920, 0, 1920, 1080)]
        let crops = PanoramaLayout.crops(displays: displays, videoSize: CGSize(width: 3840, height: 1080))
        assertRect(crops["left"], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        assertRect(crops["right"], CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    func testSideBySideWithA16By9VideoCropsTopAndBottom() {
        let displays = [display("left", 0, 0, 1920, 1080), display("right", 1920, 0, 1920, 1080)]
        let video = CGSize(width: 1920, height: 1080)
        let crops = PanoramaLayout.crops(displays: displays, videoSize: video)
        // Scaled 2x to fill 3840 wide; half of the height is visible, centred.
        assertRect(crops["left"], CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5))
        assertRect(crops["right"], CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5))
        assertContinuous(displays, crops, video: video)

        let top = PanoramaLayout.crops(displays: displays, videoSize: video, offset: CGPoint(x: 0, y: -1))
        assertRect(top["left"], CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let bottom = PanoramaLayout.crops(displays: displays, videoSize: video, offset: CGPoint(x: 0, y: 1))
        assertRect(bottom["right"], CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testStackedDisplays() {
        // AppKit coordinates: the upper display has the larger y.
        let displays = [display("lower", 0, 0, 1920, 1080), display("upper", 0, 1080, 1920, 1080)]
        let video = CGSize(width: 1920, height: 2160)
        let crops = PanoramaLayout.crops(displays: displays, videoSize: video)
        assertRect(crops["upper"], CGRect(x: 0, y: 0, width: 1, height: 0.5))
        assertRect(crops["lower"], CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        assertContinuous(displays, crops, video: video)
    }

    func testMisalignedDisplaysOfDifferentSizes() {
        // A laptop panel to the lower left of a larger external display.
        let displays = [display("laptop", 0, 0, 1512, 982), display("external", 1512, 300, 2560, 1440)]
        let video = CGSize(width: 3840, height: 2160)
        let crops = PanoramaLayout.crops(displays: displays, videoSize: video, offset: CGPoint(x: 0.3, y: -0.4))
        assertContinuous(displays, crops, video: video)

        // Offsets beyond the range are clamped rather than leaving the video.
        assertContinuous(displays, PanoramaLayout.crops(displays: displays, videoSize: video, offset: CGPoint(x: 9, y: -9)), video: video)
    }

    func testScaleFactorDoesNotChangeTheGeometry() {
        // Frames are in points; a Retina panel next to a 1x display shares
        // the picture by physical layout, not by pixel count.
        let displays = [
            Fixture.display("retina", id: 1, size: CGSize(width: 1512, height: 982)),
            Fixture.display("plain", id: 2, isPrimary: false, size: CGSize(width: 1512, height: 982))
        ]
        var plain = displays[1]
        plain.backingScaleFactor = 1
        let layout = [displays[0], plain].map { PanoramaLayout.Display(id: $0.displayUUID, frame: $0.frame) }
        let crops = PanoramaLayout.crops(displays: layout, videoSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(crops["retina"]!.width, crops["plain"]!.width, accuracy: 1e-9)
        assertContinuous(layout, crops, video: CGSize(width: 3840, height: 2160))

        // The rendition is sized for the sharpest display across the span.
        XCTAssertEqual(
            PanoramaLayout.targetPixelSize(displays: [displays[0], plain], limit: CGSize(width: 99_999, height: 99_999)),
            CGSize(width: 6048, height: 1964)
        )
    }

    func testSingleDisplayIsTheSameAsAspectFill() {
        let only = [display("only", 0, 0, 1512, 982)]
        let video = CGSize(width: 3840, height: 2160)
        let crop = PanoramaLayout.crops(displays: only, videoSize: video)["only"]!

        // Aspect fill: scale = max(1512/3840, 982/2160); centred crop.
        let scale = max(1512.0 / 3840, 982.0 / 2160)
        let visible = CGSize(width: 1512 / scale / 3840, height: 982 / scale / 2160)
        assertRect(crop, CGRect(x: (1 - visible.width) / 2, y: (1 - visible.height) / 2, width: visible.width, height: visible.height))
    }

    func testTargetPixelSizeRespectsTheDecodeLimit() {
        let displays = [
            Fixture.display("a", id: 1, size: CGSize(width: 3008, height: 1692)),
            Fixture.display("b", id: 2, isPrimary: false, size: CGSize(width: 3008, height: 1692))
        ]
        let unlimited = PanoramaLayout.targetPixelSize(displays: displays, limit: CGSize(width: 99_999, height: 99_999))
        XCTAssertEqual(unlimited, CGSize(width: 12_032, height: 3384), "the whole span, not the largest display")

        let limited = PanoramaLayout.targetPixelSize(displays: displays, limit: CGSize(width: 8192, height: 4320))
        XCTAssertEqual(limited.width, 8192)
        XCTAssertEqual(limited.width / limited.height, unlimited.width / unlimited.height, accuracy: 0.01)

        // A source without that many pixels is used as it is, never enlarged.
        XCTAssertEqual(
            OptimizationPlanner.targetPixelSize(sourcePixelSize: CGSize(width: 3840, height: 2160), maximumPixelSize: limited),
            CGSize(width: 3840, height: 2160)
        )
    }

    func testEmptyInputs() {
        XCTAssertTrue(PanoramaLayout.crops(displays: [], videoSize: CGSize(width: 10, height: 10)).isEmpty)
        XCTAssertTrue(PanoramaLayout.crops(displays: [display("a", 0, 0, 10, 10)], videoSize: .zero).isEmpty)
    }
}

@MainActor
final class PanoramaSurfaceTests: XCTestCase {
    /// Left half red, right half blue; top quarter brighter is not needed —
    /// a second image checks the vertical direction.
    private func image(width: Int = 80, height: Int = 40, fill: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        fill(context)
        return context.makeImage()!
    }

    private func render(_ view: WallpaperHostView) -> (Int, Int) -> [Int] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        view.layer!.render(in: context)
        // (x, y) with y measured from the top, like the crop rectangles.
        return { x, y in
            let offset = (y * width + x) * 4
            return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
        }
    }

    func testCropShowsTheRightPartOfThePoster() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        // Red on the left, blue on the right.
        view.setPoster(image { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        })
        view.layoutSubtreeIfNeeded()
        view.layout()

        view.setContentCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        var pixel = render(view)
        XCTAssertGreaterThan(pixel(5, 20)[2], 200, "the right half of the picture fills the display")
        XCTAssertLessThan(pixel(5, 20)[0], 50)
        XCTAssertGreaterThan(pixel(75, 20)[2], 200)

        view.setContentCrop(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        pixel = render(view)
        XCTAssertGreaterThan(pixel(75, 20)[0], 200, "now the left half")

        view.setContentCrop(nil)
        pixel = render(view)
        XCTAssertGreaterThan(pixel(5, 20)[0], 200, "without a crop the whole picture is back")
        XCTAssertGreaterThan(pixel(75, 20)[2], 200)
        XCTAssertEqual(view.contentLayerFrame, view.bounds)
    }

    func testCropIsMeasuredFromTheTop() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        // White on the top half, black below (Core Graphics y grows upwards).
        view.setPoster(image { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 20, width: 80, height: 20))
        })
        view.layout()

        view.setContentCrop(CGRect(x: 0, y: 0, width: 1, height: 0.5))
        var pixel = render(view)
        XCTAssertGreaterThan(pixel(40, 5)[0], 200, "the upper display shows the top of the picture")
        XCTAssertGreaterThan(pixel(40, 35)[0], 200)

        view.setContentCrop(CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        pixel = render(view)
        XCTAssertLessThan(pixel(40, 5)[0], 50, "the lower display shows the bottom")
        XCTAssertLessThan(pixel(40, 35)[0], 50)
    }

    func testCropAppliesToVideoLayersToo() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.layout()
        view.setContentCrop(CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5))
        // The whole picture would be 160 x 80; this display shows its right half, middle rows.
        XCTAssertEqual(view.contentLayerFrame, CGRect(x: -80, y: -20, width: 160, height: 80))
        XCTAssertEqual(view.playerLayer.frame, view.contentLayerFrame, "the direct player layer gets the same geometry")
    }
}

@MainActor
final class PanoramaSessionTests: XCTestCase {
    private var environment: FakeEnvironment!
    private var manager: WallpaperSessionManager!

    override func setUp() async throws {
        environment = FakeEnvironment()
        manager = WallpaperSessionManager(
            environment: environment, permissionStore: FakePermissionStore(), energyPolicy: EnergyPolicyController(), sleep: { _ in }
        )
    }

    private func placements(_ asset: WallpaperAsset, displays: [DisplayTarget], spans: Bool) -> [WallpaperPlacement] {
        WallpaperResolver.resolve(
            .init(displays: displays, placements: [WallpaperPlacement(assetID: asset.id, scope: .allDisplays, spansDisplays: spans)], assets: [asset])
        ).placements
    }

    func testSpanUsesOneDecoderAndGivesEachDisplayItsSlice() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset()

        await manager.reconcile(Fixture.request(displays: displays, assets: [asset], placements: placements(asset, displays: displays, spans: true)))

        XCTAssertEqual(environment.engines.count, 1, "a panorama is still decoded once")
        XCTAssertEqual(environment.engines[0].attachedCount, 2)
        let left = environment.surface(for: "a")?.crop
        let right = environment.surface(for: "b")?.crop
        XCTAssertEqual(left?.minX ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(right?.minX ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(left?.width ?? 0, 0.5, accuracy: 1e-9)
    }

    func testWithoutASpanNoSurfaceIsEverCropped() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset()
        await manager.reconcile(Fixture.request(displays: displays, assets: [asset], placements: placements(asset, displays: displays, spans: false)))
        XCTAssertTrue(environment.surfaces.allSatisfy { $0.cropHistory.isEmpty }, "the feature at its default touches nothing")
    }

    func testRemovingADisplayRecomputesSlicesWithoutRestartingPlayback() async {
        let three = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false), Fixture.display("c", id: 3, isPrimary: false)]
        let asset = Fixture.asset()

        await manager.reconcile(Fixture.request(displays: three, assets: [asset], placements: placements(asset, displays: three, spans: true)))
        let engine = environment.engines[0]
        XCTAssertEqual(environment.surface(for: "b")?.crop?.width ?? 0, 1.0 / 3, accuracy: 1e-9)

        let two = Array(three.prefix(2))
        await manager.reconcile(Fixture.request(displays: two, assets: [asset], placements: placements(asset, displays: two, spans: true)))

        XCTAssertEqual(environment.surface(for: "b")?.crop?.width ?? 0, 0.5, accuracy: 1e-9, "slices follow the new arrangement")
        XCTAssertEqual(environment.engines.count, 1)
        XCTAssertEqual(engine.prepareAttempts.count, 1, "the video was not reloaded")
        XCTAssertEqual(engine.teardownCount, 0)
        XCTAssertTrue(engine.isPlaying)

        // Down to one display: plain aspect fill, no crop.
        let one = Array(three.prefix(1))
        await manager.reconcile(Fixture.request(displays: one, assets: [asset], placements: placements(asset, displays: one, spans: true)))
        XCTAssertNil(environment.surface(for: "a")?.crop, "a single display is the normal mode")
        XCTAssertEqual(engine.prepareAttempts.count, 1)
    }

    func testNativeDesktopPicturesGetTheMatchingSlice() {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset(posterPath: "Posters/p.heic")
        let assignments = NativeDesktopPictureManager.desiredAssignments(
            displays: displays, assets: [asset], placements: placements(asset, displays: displays, spans: true)
        )
        XCTAssertEqual(assignments.map(\.crop?.minX), [0, 0.5])
        XCTAssertTrue(assignments.allSatisfy(\.needsDerivedImage), "each display gets its slice, not the whole poster")
        XCTAssertNotEqual(assignments[0].derivedFileName, assignments[1].derivedFileName)

        let plain = NativeDesktopPictureManager.desiredAssignments(
            displays: displays, assets: [asset], placements: placements(asset, displays: displays, spans: false)
        )
        XCTAssertTrue(plain.allSatisfy { $0.crop == nil })
    }
}
