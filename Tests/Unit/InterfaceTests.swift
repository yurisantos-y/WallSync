import XCTest
@testable import WallSync

/// The plain-language summaries the interface is built on.
final class InterfaceSummaryTests: XCTestCase {
    private func session(
        playback: RenderSession.PlaybackState,
        energy: RenderSession.EnergyMode,
        reason: SessionModeReason = .none
    ) -> RenderSession {
        RenderSession(
            id: UUID(), displayTarget: Fixture.display(), assetID: UUID(), windowState: .visible,
            playbackState: playback, energyMode: energy, startedAt: .now, lastVisibilityChange: .now,
            modeReason: reason
        )
    }

    func testDisplayStatusSaysWhyADisplayIsNotAnimating() {
        let animating = DisplayStatus.make(session: session(playback: .animating, energy: .animate), hasWallpaper: true)
        XCTAssertNil(animating.reason)
        XCTAssertEqual(animating.color, .green)

        let still = DisplayStatus.make(session: session(playback: .poster, energy: .poster, reason: .battery), hasWallpaper: true)
        XCTAssertEqual(still.reason, SessionModeReason.battery.localizedLabel)
        XCTAssertEqual(still.color, .orange)
        XCTAssertTrue(still.text.contains(still.title) && still.text.contains(still.reason ?? "?"))

        let suspended = DisplayStatus.make(session: session(playback: .paused, energy: .suspend, reason: .fullscreen), hasWallpaper: true)
        XCTAssertEqual(suspended.reason, SessionModeReason.fullscreen.localizedLabel)
        XCTAssertEqual(suspended.color, .gray)

        let failed = DisplayStatus.make(session: session(playback: .failed, energy: .animate), hasWallpaper: true)
        XCTAssertEqual(failed.color, .red)
    }

    func testDisplayStatusWithoutASessionTellsNoWallpaperFromNotRunning() {
        let none = DisplayStatus.make(session: nil, hasWallpaper: false)
        let stopped = DisplayStatus.make(session: nil, hasWallpaper: true)
        XCTAssertNotEqual(none.title, stopped.title)
        XCTAssertNil(none.reason)
    }

    func testAssetSummariesUseFamiliarWords() {
        var asset = Fixture.asset()
        asset.codecType = "hvc1"
        asset.pixelSize = CGSize(width: 3840, height: 2160)
        asset.sourceIsHDR = true
        XCTAssertEqual(AssetInspector.shortSummary(for: asset), "0:12 · 4K · HDR")
        XCTAssertTrue(AssetInspector.technicalSummary(for: asset).contains("HEVC"))
        XCTAssertTrue(AssetInspector.technicalSummary(for: asset).contains("3840×2160"))

        XCTAssertEqual(AssetInspector.codecName("avc1"), "H.264")
        XCTAssertEqual(AssetInspector.codecName("apcn"), "ProRes")
        XCTAssertEqual(AssetInspector.codecName("xyz"), "xyz")
        XCTAssertEqual(AssetInspector.sizeClass(CGSize(width: 1080, height: 1920)), "1080p", "portrait videos use the short side")
        XCTAssertEqual(AssetInspector.durationLabel(125), "2:05")
        XCTAssertEqual(AssetInspector.durationLabel(0), "")
    }

    func testEditSummaryIsNilWithoutEdits() {
        var asset = Fixture.asset()
        XCTAssertNil(AssetInspector.editSummary(for: asset))
        asset.editRecipe.loopCrossfade = 1
        asset.editRecipe.watermarkRegions = [CGRect(x: 0, y: 0, width: 0.1, height: 0.1)]
        XCTAssertEqual(AssetInspector.editSummary(for: asset)?.components(separatedBy: " · ").count, 2)
    }
}
