import XCTest
@testable import Wallpaper

final class WallpaperTests: XCTestCase {
    func testEligibilityEvaluatorFlagsHeavy4K60Asset() {
        let evaluator = PlaybackEligibilityEvaluator()
        let profile = evaluator.profile(
            containerType: "mp4",
            codecType: "HEVC",
            pixelSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            estimatedBitRate: 24_000_000,
            hardwareDecodeLikely: true
        )

        XCTAssertEqual(profile.tier, .warning)
        XCTAssertTrue(profile.isHeavy)
    }

    func testEnergyPolicySuspendsWhenDisplayIsFullscreen() {
        let controller = EnergyPolicyController()
        let preferences = UserPreferences.defaultValue

        let mode = controller.mode(
            for: SystemContext(
                onBattery: false,
                lowPowerMode: false,
                thermalState: .nominal,
                isOccluded: false,
                isFullscreen: true,
                assetIsHeavy: false,
                isPrimaryDisplay: true,
                activeDisplayCount: 1
            ),
            preferences: preferences
        )

        XCTAssertEqual(mode, .suspend)
    }

    func testEnergyPolicyKeepsSuspendedPlaybackWarmInBalancedMode() {
        let controller = EnergyPolicyController()
        var preferences = UserPreferences.defaultValue
        preferences.fallbackMode = .balanced

        let context = SystemContext(
            onBattery: false,
            lowPowerMode: false,
            thermalState: .nominal,
            isOccluded: true,
            isFullscreen: false,
            assetIsHeavy: true,
            isPrimaryDisplay: true,
            activeDisplayCount: 2
        )

        XCTAssertFalse(controller.shouldUnloadSuspendedPlayback(for: context, preferences: preferences))
    }

    func testEnergyPolicyUnloadsSuspendedPlaybackInBatterySaverMode() {
        let controller = EnergyPolicyController()
        var preferences = UserPreferences.defaultValue
        preferences.fallbackMode = .batterySaver

        let context = SystemContext(
            onBattery: true,
            lowPowerMode: false,
            thermalState: .nominal,
            isOccluded: true,
            isFullscreen: false,
            assetIsHeavy: true,
            isPrimaryDisplay: false,
            activeDisplayCount: 2
        )

        XCTAssertTrue(controller.shouldUnloadSuspendedPlayback(for: context, preferences: preferences))
        XCTAssertEqual(controller.suspendedPlaybackGracePeriod(for: context, preferences: preferences), .seconds(4))
    }

    func testEnergyPolicyUnloadsImmediatelyUnderCriticalThermals() {
        let controller = EnergyPolicyController()
        let preferences = UserPreferences.defaultValue

        let context = SystemContext(
            onBattery: false,
            lowPowerMode: false,
            thermalState: .critical,
            isOccluded: true,
            isFullscreen: true,
            assetIsHeavy: false,
            isPrimaryDisplay: true,
            activeDisplayCount: 1
        )

        XCTAssertTrue(controller.shouldUnloadSuspendedPlayback(for: context, preferences: preferences))
        XCTAssertEqual(controller.suspendedPlaybackGracePeriod(for: context, preferences: preferences), .seconds(2))
    }

    func testSessionPolicyFallsBackToGlobalPlacement() {
        let display = DisplayTarget(
            displayUUID: "display-1",
            cgDisplayID: 1,
            localizedName: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 3024, height: 1964),
            backingScaleFactor: 2,
            isPrimary: true,
            maximumFramesPerSecond: 60,
            hasSeparateSpaceContext: true
        )

        let asset = WallpaperAsset(
            id: UUID(),
            displayName: "Loop",
            originalBookmarkID: UUID(),
            originalPathHint: "/tmp/loop.mp4",
            containerType: "mp4",
            codecType: "HEVC",
            pixelSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            estimatedBitRate: 8_000_000,
            duration: 12,
            hasAudio: false,
            posterImageRelativePath: nil,
            eligibility: .safeDefault,
            importedAt: .now
        )

        let placements = [
            WallpaperPlacement(assetID: asset.id, scope: .allDisplays, contentMode: .aspectFill)
        ]

        let desiredSessions = SessionReconciliationPolicy().desiredSessions(
            displays: [display],
            assets: [asset],
            placements: placements
        )

        XCTAssertEqual(desiredSessions.count, 1)
        XCTAssertEqual(desiredSessions.first?.asset.id, asset.id)
        XCTAssertEqual(desiredSessions.first?.placement.contentMode, .aspectFill)
    }

    func testSessionPolicyPrefersSpecificDisplayPlacement() {
        let display = DisplayTarget(
            displayUUID: "display-1",
            cgDisplayID: 1,
            localizedName: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 3024, height: 1964),
            backingScaleFactor: 2,
            isPrimary: true,
            maximumFramesPerSecond: 60,
            hasSeparateSpaceContext: true
        )

        let assetID = UUID()
        let placements = [
            WallpaperPlacement(assetID: UUID(), scope: .allDisplays, contentMode: .aspectFill),
            WallpaperPlacement(assetID: assetID, scope: .specificDisplay(display.displayUUID), contentMode: .aspectFit)
        ]

        let resolvedPlacement = SessionReconciliationPolicy().resolvedPlacement(for: display, placements: placements)

        XCTAssertEqual(resolvedPlacement?.assetID, assetID)
        XCTAssertEqual(resolvedPlacement?.contentMode, .aspectFit)
    }

    func testFullscreenDetectorIgnoresHigherLayerSystemWindows() {
        let display = makeDisplayTarget()
        let detector = FullscreenWindowDetector()

        let fullscreenDisplays = detector.fullscreenDisplayUUIDs(
            displays: [display],
            excludingProcessID: 999,
            windows: [
                makeWindowInfo(owner: "Dock", pid: 100, layer: 20, bounds: display.frame)
            ]
        )

        XCTAssertTrue(fullscreenDisplays.isEmpty)
    }

    func testFullscreenDetectorMarksNormalFullscreenAppWindows() {
        let display = makeDisplayTarget()
        let detector = FullscreenWindowDetector()

        let fullscreenDisplays = detector.fullscreenDisplayUUIDs(
            displays: [display],
            excludingProcessID: 999,
            windows: [
                makeWindowInfo(owner: "Google Chrome", pid: 100, layer: 0, bounds: display.frame)
            ]
        )

        XCTAssertEqual(fullscreenDisplays, [display.displayUUID])
    }

    func testFullscreenDetectorIgnoresNearlyFullscreenWindowsBelowThreshold() {
        let display = makeDisplayTarget()
        let detector = FullscreenWindowDetector()

        let almostFullscreen = CGRect(
            x: display.frame.minX,
            y: display.frame.minY,
            width: display.frame.width * 0.96,
            height: display.frame.height
        )

        let fullscreenDisplays = detector.fullscreenDisplayUUIDs(
            displays: [display],
            excludingProcessID: 999,
            windows: [
                makeWindowInfo(owner: "Xcode", pid: 100, layer: 0, bounds: almostFullscreen)
            ]
        )

        XCTAssertTrue(fullscreenDisplays.isEmpty)
    }
}

private func makeDisplayTarget() -> DisplayTarget {
    DisplayTarget(
        displayUUID: "display-1",
        cgDisplayID: 1,
        localizedName: "Studio Display",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2,
        isPrimary: true,
        maximumFramesPerSecond: 60,
        hasSeparateSpaceContext: true
    )
}

private func makeWindowInfo(
    owner: String,
    pid: Int32,
    layer: Int,
    alpha: Double = 1,
    bounds: CGRect
) -> [String: Any] {
    [
        kCGWindowOwnerName as String: owner,
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowAlpha as String: NSNumber(value: alpha),
        kCGWindowBounds as String: [
            "X": bounds.origin.x,
            "Y": bounds.origin.y,
            "Width": bounds.size.width,
            "Height": bounds.size.height
        ]
    ]
}
