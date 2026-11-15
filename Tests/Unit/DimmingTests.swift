import AVFoundation
import XCTest
@testable import WallSync

final class DimmingPolicyTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertNil(DimmingPolicy.overlay(for: Fixture.asset(), settings: .off, isDarkAppearance: false))
        XCTAssertNil(DimmingPolicy.overlay(for: Fixture.asset(), settings: .off, isDarkAppearance: true))
        XCTAssertEqual(UserPreferences.defaultValue.dimming, .off)
    }

    func testAmountTintAndClamp() {
        var settings = DimmingSettings(amount: 0.4)
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: false), DimOverlay(opacity: 0.4, color: .black))

        settings.tint = RGBColor(red: 0.1, green: 0.2, blue: 0.3)
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: false)?.color, settings.tint)

        settings.amount = 5
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: false)?.opacity, DimmingSettings.maximum)
    }

    func testDarkAppearanceAddsExtraOnlyWhenEnabled() throws {
        var settings = DimmingSettings(amount: 0.3)
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: true)?.opacity, 0.3)
        settings.dimMoreInDarkMode = true
        XCTAssertEqual(try XCTUnwrap(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: true)).opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: false)?.opacity, 0.3)

        settings.amount = 0.75
        XCTAssertEqual(DimmingPolicy.overlay(for: Fixture.asset(), settings: settings, isDarkAppearance: true)?.opacity, 0.8, "never beyond the maximum")
    }

    func testAssetOverrideReplacesTheGlobalAmount() {
        var asset = Fixture.asset()
        asset.dimmingOverride = 0.6
        XCTAssertEqual(DimmingPolicy.overlay(for: asset, settings: DimmingSettings(amount: 0.1), isDarkAppearance: false)?.opacity, 0.6)
        asset.dimmingOverride = 0
        XCTAssertNil(DimmingPolicy.overlay(for: asset, settings: DimmingSettings(amount: 0.5), isDarkAppearance: false))
    }

    func testPreferencesWithoutDimmingStillLoad() throws {
        let legacy = #"{"launchAtLogin":false,"startOnLaunch":true,"reduceOnBattery":true,"pauseWhenFullscreen":true,"pauseWhenOccluded":true,"fallbackMode":"balanced"}"#
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.dimming, .off)

        var preferences = UserPreferences.defaultValue
        preferences.dimming = DimmingSettings(amount: 0.35, tint: RGBColor(red: 1, green: 0, blue: 0), dimMoreInDarkMode: true)
        XCTAssertEqual(try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
}

@MainActor
final class DimmingLayerTests: XCTestCase {
    func testLayerExistsOnlyWhileDimmingIsConfigured() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let baseline = view.rootSublayerCount
        XCTAssertFalse(view.hasDimmingLayer)

        view.setDimming(DimOverlay(opacity: 0.4, color: .black))
        XCTAssertTrue(view.hasDimmingLayer)
        XCTAssertEqual(view.rootSublayerCount, baseline + 1)

        view.setDimming(DimOverlay(opacity: 0.6, color: RGBColor(red: 0, green: 0, blue: 1)))
        XCTAssertEqual(view.rootSublayerCount, baseline + 1, "changing the amount reuses the layer")

        view.setDimming(nil)
        XCTAssertFalse(view.hasDimmingLayer)
        XCTAssertEqual(view.rootSublayerCount, baseline, "with dimming off the tree is exactly as before")
    }

    func testDimmingLayerSitsAboveVideoAndLeavesItsSettingsAlone() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.setWantsExtendedDynamicRange(true)
        view.setDimming(DimOverlay(opacity: 0.5, color: .black))

        let top = view.layer?.sublayers?.last
        XCTAssertEqual(top?.opacity, 0.5)
        XCTAssertFalse(top === view.playerLayer.superlayer)
        XCTAssertTrue(view.playerLayer.wantsExtendedDynamicRangeContent, "HDR output is not switched off by dimming")
    }
}

final class DerivedPosterTests: XCTestCase {
    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 40, height: Int = 20) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes.prefix(3).map(Int.init)
    }

    func testDimmedPosterMatchesTheLayerBlend() throws {
        let poster = solid(1, 0.5, 0)
        let dimmed = try XCTUnwrap(
            DerivedPosterRenderer.image(from: poster, dimming: DimOverlay(opacity: 0.4, color: RGBColor(red: 0, green: 0, blue: 1)), crop: nil)
        )
        // out = (1 - a) * poster + a * tint, per channel, in sRGB.
        let expected = [Int((0.6 * 255).rounded()), Int((0.6 * 127.5).rounded()), Int((0.4 * 255).rounded())]
        let actual = pixel(dimmed, x: 10, y: 10)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 2) }
        XCTAssertEqual(dimmed.width, poster.width)
    }

    func testUndimmedUncroppedPosterIsUsedAsIs() {
        let assignment = NativeDesktopPictureAssignment(
            displayUUID: "a", cgDisplayID: 1, posterImageRelativePath: "Posters/x.heic", contentMode: .aspectFill
        )
        XCTAssertFalse(assignment.needsDerivedImage, "no derived file, no extra work, when the feature is off")
    }

    func testDerivedFileNameIsStableAndSpecific() {
        var assignment = NativeDesktopPictureAssignment(
            displayUUID: "a", cgDisplayID: 1, posterImageRelativePath: "Posters/x.heic", contentMode: .aspectFill,
            dimming: DimOverlay(opacity: 0.4, color: .black)
        )
        XCTAssertEqual(assignment.derivedFileName, "x-d400-000000.heic")
        assignment.dimming?.opacity = 0.45
        XCTAssertEqual(assignment.derivedFileName, "x-d450-000000.heic")
        assignment.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        XCTAssertEqual(assignment.derivedFileName, "x-d450-000000-c5000_0_5000_10000.heic")
    }

    func testDesiredAssignmentsCarryTheDimming() {
        let display = Fixture.display()
        let asset = Fixture.asset(posterPath: "Posters/p.heic")
        let placements = [WallpaperPlacement(assetID: asset.id, scope: .allDisplays)]

        let plain = NativeDesktopPictureManager.desiredAssignments(displays: [display], assets: [asset], placements: placements)
        XCTAssertNil(plain.first?.dimming)

        let dimmed = NativeDesktopPictureManager.desiredAssignments(
            displays: [display], assets: [asset], placements: placements,
            dimming: DimmingSettings(amount: 0.25), isDarkAppearance: false
        )
        XCTAssertEqual(dimmed.first?.dimming, DimOverlay(opacity: 0.25, color: .black))
    }

    func testRenderWritesTheDerivedFile() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("poster.heic")
        try PosterCacheStore.write(solid(1, 1, 1, width: 64, height: 32), to: source, type: .heic, quality: 0.9)
        let destination = directory.appendingPathComponent("DesktopPictures/out.heic")

        XCTAssertTrue(
            DerivedPosterRenderer.render(
                from: source, to: destination,
                dimming: DimOverlay(opacity: 0.5, color: .black), crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            )
        )
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(written.width, 32)
        XCTAssertEqual(written.height, 32)
        XCTAssertEqual(pixel(written, x: 5, y: 5)[0], 128, accuracy: 6)
    }
}
