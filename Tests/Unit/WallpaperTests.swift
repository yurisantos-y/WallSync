import AVFoundation
import XCTest
@testable import WallSync

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
        XCTAssertEqual(controller.suspendedPlaybackGracePeriod(for: context, preferences: preferences), .seconds(8))
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

    func testEnergyPolicyUnloadsPosterPlaybackForCriticalThermals() {
        let controller = EnergyPolicyController()
        let preferences = UserPreferences.defaultValue
        let context = SystemContext(
            onBattery: false,
            lowPowerMode: false,
            thermalState: .critical,
            isOccluded: false,
            isFullscreen: false,
            assetIsHeavy: false,
            isPrimaryDisplay: true,
            activeDisplayCount: 1
        )

        XCTAssertTrue(controller.shouldUnloadPlayback(for: .poster, context: context, preferences: preferences))
        XCTAssertEqual(controller.playbackUnloadGracePeriod(for: .poster, context: context, preferences: preferences), .seconds(2))
    }

    func testEnergyPolicyUnloadsPosterPlaybackForLowPowerHeavyAsset() {
        let controller = EnergyPolicyController()
        let preferences = UserPreferences.defaultValue
        let context = SystemContext(
            onBattery: false,
            lowPowerMode: true,
            thermalState: .nominal,
            isOccluded: false,
            isFullscreen: false,
            assetIsHeavy: true,
            isPrimaryDisplay: true,
            activeDisplayCount: 1
        )

        XCTAssertTrue(controller.shouldUnloadPlayback(for: .poster, context: context, preferences: preferences))
        XCTAssertEqual(controller.playbackUnloadGracePeriod(for: .poster, context: context, preferences: preferences), .seconds(8))
    }

    func testEnergyPolicyUnloadsPosterPlaybackForBatterySaverSecondaryDisplay() {
        let controller = EnergyPolicyController()
        var preferences = UserPreferences.defaultValue
        preferences.fallbackMode = .batterySaver
        let context = SystemContext(
            onBattery: false,
            lowPowerMode: false,
            thermalState: .nominal,
            isOccluded: false,
            isFullscreen: false,
            assetIsHeavy: false,
            isPrimaryDisplay: false,
            activeDisplayCount: 2
        )

        XCTAssertTrue(controller.shouldUnloadPlayback(for: .poster, context: context, preferences: preferences))
        XCTAssertEqual(controller.playbackUnloadGracePeriod(for: .poster, context: context, preferences: preferences), .seconds(12))
    }

    func testReleaseSettingsDoNotEnableCodeCoverage() throws {
        let projectFile = repositoryRoot()
            .appendingPathComponent("Wallpaper.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        let project = try String(contentsOf: projectFile)

        XCTAssertTrue(project.contains("ENABLE_CODE_COVERAGE = NO;"))
        XCTAssertTrue(project.contains("CLANG_COVERAGE_MAPPING = NO;"))
        XCTAssertTrue(project.contains("GCC_GENERATE_TEST_COVERAGE_FILES = NO;"))
        XCTAssertTrue(project.contains("GCC_INSTRUMENT_PROGRAM_FLOW_ARCS = NO;"))
        XCTAssertFalse(project.contains("ENABLE_CODE_COVERAGE = YES;"))
        XCTAssertFalse(project.contains("CLANG_COVERAGE_MAPPING = YES;"))
        XCTAssertFalse(project.contains("GCC_GENERATE_TEST_COVERAGE_FILES = YES;"))
        XCTAssertFalse(project.contains("GCC_INSTRUMENT_PROGRAM_FLOW_ARCS = YES;"))
    }

    func testLegacyAssetsDecodeWithoutOptimizedPlayback() throws {
        let json = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "displayName": "Legacy Loop",
            "originalBookmarkID": "22222222-2222-2222-2222-222222222222",
            "originalPathHint": "/tmp/legacy.mp4",
            "containerType": "mp4",
            "codecType": "HEVC",
            "pixelSize": [1920, 1080],
            "frameRate": 30,
            "estimatedBitRate": 8000000,
            "duration": 12,
            "hasAudio": false,
            "posterImageRelativePath": null,
            "eligibility": {
              "tier": "safe",
              "hardwareDecodeLikely": true,
              "reasonCodes": [],
              "isHeavy": false,
              "recommendedMode": "animate"
            },
            "importedAt": 0
          }
        ]
        """.data(using: .utf8)!

        let assets = try JSONDecoder().decode([WallpaperAsset].self, from: json)

        XCTAssertEqual(assets.first?.displayName, "Legacy Loop")
        XCTAssertNil(assets.first?.optimizedPlayback)
        XCTAssertEqual(assets.first?.originalPathHint, "/tmp/legacy.mp4")
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

    func testNativeDesktopPictureAssignmentsUseResolvedPostersPerDisplay() {
        let primaryDisplay = makeDisplayTarget(displayUUID: "display-1", cgDisplayID: 1, isPrimary: true)
        let secondaryDisplay = makeDisplayTarget(displayUUID: "display-2", cgDisplayID: 2, isPrimary: false)
        let globalAsset = makeWallpaperAsset(posterImageRelativePath: "Posters/global.png")
        let secondaryAsset = makeWallpaperAsset(posterImageRelativePath: "Posters/secondary.png")
        let missingPosterAsset = makeWallpaperAsset(posterImageRelativePath: nil)

        let assignments = NativeDesktopPictureManager.desiredAssignments(
            displays: [primaryDisplay, secondaryDisplay],
            assets: [globalAsset, secondaryAsset, missingPosterAsset],
            placements: [
                WallpaperPlacement(assetID: globalAsset.id, scope: .allDisplays, contentMode: .aspectFill),
                WallpaperPlacement(assetID: secondaryAsset.id, scope: .specificDisplay(secondaryDisplay.displayUUID), contentMode: .aspectFit)
            ]
        )

        XCTAssertEqual(
            assignments,
            [
                NativeDesktopPictureAssignment(
                    displayUUID: primaryDisplay.displayUUID,
                    cgDisplayID: primaryDisplay.cgDisplayID,
                    posterImageRelativePath: "Posters/global.png",
                    contentMode: .aspectFill
                ),
                NativeDesktopPictureAssignment(
                    displayUUID: secondaryDisplay.displayUUID,
                    cgDisplayID: secondaryDisplay.cgDisplayID,
                    posterImageRelativePath: "Posters/secondary.png",
                    contentMode: .aspectFit
                )
            ]
        )
    }

    func testNativeDesktopPictureAssignmentsSkipAssetsWithoutPoster() {
        let display = makeDisplayTarget()
        let asset = makeWallpaperAsset(posterImageRelativePath: nil)

        let assignments = NativeDesktopPictureManager.desiredAssignments(
            displays: [display],
            assets: [asset],
            placements: [
                WallpaperPlacement(assetID: asset.id, scope: .allDisplays)
            ]
        )

        XCTAssertTrue(assignments.isEmpty)
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

    func testOcclusionDetectorIgnoresPartialCoverageBelowThreshold() {
        let display = makeDisplayTarget()
        let detector = DisplayOcclusionDetector()
        let partial = CGRect(
            x: display.frame.minX,
            y: display.frame.minY,
            width: display.frame.width * 0.94,
            height: display.frame.height
        )

        XCTAssertFalse(
            detector.isDisplayCovered(
                display,
                windows: [makeWindowInfo(owner: "Xcode", pid: 100, layer: 0, bounds: partial)]
            )
        )
    }

    func testOcclusionDetectorMarksNearlyTotalCoverage() {
        let display = makeDisplayTarget()
        let detector = DisplayOcclusionDetector()
        let coveringWindow = CGRect(
            x: display.frame.minX,
            y: display.frame.minY,
            width: display.frame.width * 0.95,
            height: display.frame.height
        )

        XCTAssertTrue(
            detector.isDisplayCovered(
                display,
                windows: [makeWindowInfo(owner: "Safari", pid: 100, layer: 0, bounds: coveringWindow)]
            )
        )
    }

    func testVideoOptimizerTargetsDisplaySizeThirtyFPSAndClampedBitrate() {
        let targetSize = VideoAssetOptimizer.targetPixelSize(
            sourcePixelSize: CGSize(width: 3840, height: 2160),
            maximumPixelSize: CGSize(width: 2560, height: 1440)
        )
        let bitRate = VideoAssetOptimizer.targetBitRate(
            sourceBitRate: 50_000_000,
            pixelSize: targetSize,
            frameRate: 30
        )

        XCTAssertEqual(targetSize, CGSize(width: 2560, height: 1440))
        XCTAssertEqual(bitRate, 7_741_440, accuracy: 1)
    }

    func testPosterGeneratorRespectsMaximumPixelSize() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        try makeTemporaryVideo(at: temporaryURL, size: CGSize(width: 640, height: 480))

        let poster = try await PosterFrameGenerator().generatePoster(
            for: temporaryURL,
            maxPixelSize: CGSize(width: 160, height: 120)
        )
        let representation = try XCTUnwrap(poster.representations.first)

        XCTAssertLessThanOrEqual(representation.pixelsWide, 160)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 120)
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeDisplayTarget(
    displayUUID: String = "display-1",
    cgDisplayID: UInt32 = 1,
    isPrimary: Bool = true
) -> DisplayTarget {
    DisplayTarget(
        displayUUID: displayUUID,
        cgDisplayID: cgDisplayID,
        localizedName: "Studio Display",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2,
        isPrimary: isPrimary,
        maximumFramesPerSecond: 60,
        hasSeparateSpaceContext: true
    )
}

private func makeWallpaperAsset(posterImageRelativePath: String?) -> WallpaperAsset {
    WallpaperAsset(
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
        posterImageRelativePath: posterImageRelativePath,
        eligibility: .safeDefault,
        importedAt: .now
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

private func makeTemporaryVideo(at url: URL, size: CGSize) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
    )

    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let buffer = try makePixelBuffer(size: size)
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
    }
    adaptor.append(buffer, withPresentationTime: .zero)
    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()

    if writer.status != .completed {
        throw writer.error ?? TestVideoError.writerFailed
    }
}

private func makePixelBuffer(size: CGSize) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(size.width),
        Int(size.height),
        kCVPixelFormatType_32ARGB,
        [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary,
        &pixelBuffer
    )

    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw TestVideoError.pixelBufferFailed
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, 0x7F, CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    return pixelBuffer
}

private enum TestVideoError: Error {
    case writerFailed
    case pixelBufferFailed
}
