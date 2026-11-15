import AVFoundation
import XCTest
@testable import WallSync

final class OptimizationPlannerTests: XCTestCase {
    private func source(_ configure: (inout SourceVideoDescription) -> Void = { _ in }) -> SourceVideoDescription {
        var source = SourceVideoDescription(
            codec: "HEVC", pixelSize: CGSize(width: 1920, height: 1080), frameRate: 30, bitRate: 6_000_000,
            bitDepth: 8, isHDR: false, hardwareDecodable: true, hasTransform: false
        )
        configure(&source)
        return source
    }

    private func target(
        _ size: CGSize = CGSize(width: 3840, height: 2160),
        quality: UserPreferences.PlaybackQuality = .efficiency
    ) -> OptimizationTarget {
        OptimizationTarget(maximumPixelSize: size, quality: quality)
    }

    private func transcodePlan(_ plan: OptimizationPlan, file: StaticString = #filePath, line: UInt = #line) -> TranscodePlan? {
        guard case let .transcode(transcode) = plan else {
            XCTFail("expected a transcode, got \(plan)", file: file, line: line)
            return nil
        }
        return transcode
    }

    func testSuitableSourceIsNotReencoded() {
        XCTAssertEqual(OptimizationPlanner.plan(source: source(), target: target()), .passthrough)
        XCTAssertEqual(OptimizationPlanner.plan(source: source { $0.codec = "H264" }, target: target()), .passthrough)
    }

    func testTenBitHDRHEVCStaysUntouched() {
        let hdr = source {
            $0.bitDepth = 10
            $0.isHDR = true
            $0.pixelSize = CGSize(width: 3840, height: 2160)
            $0.bitRate = 20_000_000
        }
        XCTAssertEqual(OptimizationPlanner.plan(source: hdr, target: target()), .passthrough)
    }

    func testEachUnsuitablePropertyForcesTranscode() {
        let cases: [(String, (inout SourceVideoDescription) -> Void)] = [
            ("codec", { $0.codec = "ProRes" }),
            ("software decode", { $0.hardwareDecodable = false }),
            ("too large", { $0.pixelSize = CGSize(width: 7680, height: 4320) }),
            ("too fast", { $0.frameRate = 60 }),
            ("bit rate", { $0.bitRate = 80_000_000 }),
            ("unknown bit rate", { $0.bitRate = 0 }),
            ("rotated", { $0.hasTransform = true }),
            ("odd dimensions", { $0.pixelSize = CGSize(width: 1921, height: 1080) }),
            ("10-bit H.264", { $0.codec = "H264"; $0.bitDepth = 10 })
        ]

        for (name, configure) in cases {
            if case .passthrough = OptimizationPlanner.plan(source: source(configure), target: target()) {
                XCTFail("\(name) must not be passed through")
            }
        }
    }

    func testSixtyFramesPerSecondPassesThroughOnlyInSmoothQuality() {
        let sixty = source { $0.frameRate = 60; $0.bitRate = 10_000_000 }
        XCTAssertEqual(transcodePlan(OptimizationPlanner.plan(source: sixty, target: target()))?.frameRate, 30)
        XCTAssertEqual(OptimizationPlanner.plan(source: sixty, target: target(quality: .smooth)), .passthrough)
    }

    func testTranscodeTargetsDisplaySizeFrameRateAndBitRate() throws {
        let plan = try XCTUnwrap(transcodePlan(OptimizationPlanner.plan(
            source: source {
                $0.codec = "ProRes"
                $0.pixelSize = CGSize(width: 3840, height: 2160)
                $0.frameRate = 59.94
                $0.bitRate = 500_000_000
            },
            target: target(CGSize(width: 2560, height: 1440))
        )))

        XCTAssertEqual(plan.codec, .hevc)
        XCTAssertEqual(plan.pixelSize, CGSize(width: 2560, height: 1440))
        XCTAssertEqual(plan.frameRate, 30)
        XCTAssertEqual(plan.bitRate, 7_741_440, accuracy: 1)
        XCTAssertFalse(plan.isTenBit)
        XCTAssertFalse(plan.preservesHDR)
    }

    func testSmoothQualityAllowsUpToSixtyFramesPerSecond() throws {
        let plan = try XCTUnwrap(transcodePlan(OptimizationPlanner.plan(
            source: source { $0.codec = "ProRes"; $0.frameRate = 120; $0.bitRate = 0 },
            target: target(quality: .smooth)
        )))
        XCTAssertEqual(plan.frameRate, 60)
        XCTAssertEqual(plan.bitRate, 1920 * 1080 * 60 * 0.07, accuracy: 1)
    }

    func testHDRTranscodeKeepsTenBitsAndHDR() throws {
        let plan = try XCTUnwrap(transcodePlan(OptimizationPlanner.plan(
            source: source {
                $0.pixelSize = CGSize(width: 7680, height: 4320)
                $0.bitDepth = 10
                $0.isHDR = true
            },
            target: target()
        )))
        XCTAssertEqual(plan.codec, .hevc)
        XCTAssertTrue(plan.isTenBit)
        XCTAssertTrue(plan.preservesHDR)
        XCTAssertEqual(plan.pixelSize, CGSize(width: 3840, height: 2160))
    }

    func testSDRSourceStaysSDR() throws {
        let plan = try XCTUnwrap(transcodePlan(OptimizationPlanner.plan(source: source { $0.codec = "ProRes" }, target: target())))
        XCTAssertFalse(plan.isTenBit)
        XCTAssertFalse(plan.preservesHDR)
    }

    func testNeverUpscales() {
        XCTAssertEqual(
            OptimizationPlanner.targetPixelSize(
                sourcePixelSize: CGSize(width: 1280, height: 720),
                maximumPixelSize: CGSize(width: 5120, height: 2880)
            ),
            CGSize(width: 1280, height: 720)
        )
    }

    func testBitRateNeverExceedsSource() {
        XCTAssertEqual(
            OptimizationPlanner.targetBitRate(sourceBitRate: 2_000_000, pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30),
            2_000_000
        )
    }

    // MARK: Reoptimization

    private func optimizedAsset(
        source: CGSize,
        rendition: CGSize,
        sourceFrameRate: Double = 30,
        renditionFrameRate: Double = 30
    ) -> WallpaperAsset {
        var asset = Fixture.asset()
        asset.pixelSize = source
        asset.frameRate = sourceFrameRate
        asset.optimizedPlayback?.pixelSize = rendition
        asset.optimizedPlayback?.frameRate = renditionFrameRate
        asset.optimizedPlayback?.targetPixelSize = rendition
        return asset
    }

    func testBiggerDisplayTriggersReoptimizationWhenSourceHasThePixels() {
        let asset = optimizedAsset(source: CGSize(width: 3840, height: 2160), rendition: CGSize(width: 1920, height: 1080))
        XCTAssertTrue(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: CGSize(width: 3840, height: 2160), quality: .efficiency))
        XCTAssertFalse(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: CGSize(width: 1920, height: 1080), quality: .efficiency))
    }

    func testNoReoptimizationWhenSourceIsAlreadyFullyUsed() {
        let asset = optimizedAsset(source: CGSize(width: 1920, height: 1080), rendition: CGSize(width: 1920, height: 1080))
        XCTAssertFalse(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: CGSize(width: 6016, height: 3384), quality: .efficiency))
    }

    func testSmallerDisplayNeverDowngrades() {
        let asset = optimizedAsset(source: CGSize(width: 3840, height: 2160), rendition: CGSize(width: 3840, height: 2160))
        XCTAssertFalse(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: CGSize(width: 1280, height: 720), quality: .efficiency))
    }

    func testRaisingFrameRateCeilingTriggersReoptimization() {
        let asset = optimizedAsset(
            source: CGSize(width: 1920, height: 1080), rendition: CGSize(width: 1920, height: 1080),
            sourceFrameRate: 60, renditionFrameRate: 30
        )
        let display = CGSize(width: 1920, height: 1080)
        XCTAssertFalse(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: display, quality: .efficiency))
        XCTAssertTrue(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: display, quality: .smooth))
    }

    func testPendingOrUnoptimizedAssetsAreNotReoptimized() {
        var pending = Fixture.asset(optimized: false)
        pending.optimizationState = .pending
        XCTAssertFalse(OptimizationPlanner.needsReoptimization(asset: pending, maximumPixelSize: CGSize(width: 9999, height: 9999), quality: .smooth))
    }

    func testLargestDisplayPixelSize() {
        let displays = [
            Fixture.display("a", id: 1, size: CGSize(width: 1512, height: 982)),
            Fixture.display("b", id: 2, isPrimary: false, size: CGSize(width: 2560, height: 1440))
        ]
        XCTAssertEqual(displays.largestPixelSize, CGSize(width: 5120, height: 2880))
        XCTAssertEqual([DisplayTarget]().largestPixelSize, CGSize(width: 1920, height: 1080))
    }
}

final class CatalogCompatibilityTests: XCTestCase {
    func testAssetWrittenBeforeOptimizerMetadataDecodes() throws {
        let json = """
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Old", "originalBookmarkID": "22222222-2222-2222-2222-222222222222",
          "originalPathHint": "/tmp/old.mov", "containerType": "mov", "codecType": "HEVC",
          "pixelSize": [3840, 2160], "frameRate": 60, "estimatedBitRate": 40000000, "duration": 20,
          "hasAudio": true, "posterImageRelativePath": "Posters/11111111-1111-1111-1111-111111111111.png",
          "optimizedPlayback": {
            "relativePath": "OptimizedVideos/11111111-1111-1111-1111-111111111111.mp4",
            "codecType": "HEVC", "pixelSize": [2560, 1440], "frameRate": 30,
            "estimatedBitRate": 7741440, "duration": 20
          },
          "eligibility": {"tier": "unsupported", "hardwareDecodeLikely": true,
                          "reasonCodes": ["exceeds_mvp_limits"], "isHeavy": true, "recommendedMode": "unsupported"},
          "importedAt": 700000000
        }]
        """.data(using: .utf8)!

        let asset = try XCTUnwrap(JSONDecoder().decode([WallpaperAsset].self, from: json).first)

        XCTAssertEqual(asset.optimizationState, .ready)
        XCTAssertNil(asset.thumbnailRelativePath)
        XCTAssertFalse(asset.originalUnavailable)
        XCTAssertEqual(asset.sourceBitDepth, 8)
        let rendition = try XCTUnwrap(asset.optimizedPlayback)
        XCTAssertNil(rendition.targetPixelSize)
        XCTAssertFalse(rendition.isPassthrough)
        XCTAssertFalse(rendition.isHDR)
        XCTAssertEqual(rendition.bitDepth, 8)
        // The old PNG poster and the un-suffixed rendition are still referenced.
        XCTAssertEqual(
            OrphanCleanupPolicy.relativePaths(ownedBy: asset),
            ["Posters/11111111-1111-1111-1111-111111111111.png", "OptimizedVideos/11111111-1111-1111-1111-111111111111.mp4"]
        )
        // An asset the old version marked unsupported is playable through its rendition.
        XCTAssertNotEqual(PlaybackEligibilityEvaluator().effectiveProfile(for: asset).tier, .unsupported)
        XCTAssertFalse(AssetInspector.reasonLabel(for: "exceeds_mvp_limits").lowercased().contains("mvp"))
    }

    func testLegacyAssetWithoutRenditionIsQueuedForOptimization() throws {
        let json = """
        [{"id": "11111111-1111-1111-1111-111111111111", "displayName": "Legacy",
          "originalBookmarkID": "22222222-2222-2222-2222-222222222222", "originalPathHint": "/tmp/l.mp4",
          "containerType": "mp4", "codecType": "HEVC", "pixelSize": [1920, 1080], "frameRate": 30,
          "estimatedBitRate": 8000000, "duration": 12, "hasAudio": false, "posterImageRelativePath": null,
          "eligibility": {"tier": "safe", "hardwareDecodeLikely": true, "reasonCodes": [], "isHeavy": false, "recommendedMode": "animate"},
          "importedAt": 0}]
        """.data(using: .utf8)!

        let asset = try XCTUnwrap(JSONDecoder().decode([WallpaperAsset].self, from: json).first)
        XCTAssertEqual(asset.optimizationState, .pending)
    }

    func testCurrentAssetRoundTrips() throws {
        var asset = Fixture.asset(posterPath: "Posters/a.heic")
        asset.thumbnailRelativePath = "Posters/a-thumb.heic"
        asset.optimizationState = .failed
        asset.originalUnavailable = true
        asset.sourceBitDepth = 10
        asset.sourceIsHDR = true
        asset.optimizedPlayback?.targetPixelSize = CGSize(width: 5120, height: 2880)
        asset.optimizedPlayback?.frameRateCap = 60
        asset.optimizedPlayback?.isPassthrough = true
        asset.optimizedPlayback?.bitDepth = 10
        asset.optimizedPlayback?.isHDR = true

        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(WallpaperAsset.self, from: encoder.encode(asset))
        XCTAssertEqual(decoded.optimizedPlayback, asset.optimizedPlayback)
        XCTAssertEqual(decoded.thumbnailRelativePath, asset.thumbnailRelativePath)
        XCTAssertEqual(decoded.optimizationState, .failed)
        XCTAssertTrue(decoded.originalUnavailable)
        XCTAssertTrue(decoded.sourceIsHDR)
        XCTAssertTrue(OrphanCleanupPolicy.relativePaths(ownedBy: decoded).contains("Posters/a-thumb.heic"))
    }
}

/// Runs the real optimizer on clips synthesized at test time.
final class VideoOptimizerIntegrationTests: XCTestCase {
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

    private func optimizedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: storage.optimizedDirectory.path).sorted()
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
        var values: [Double] { lock.withLock { storage } }
    }

    func testTranscodeProducesVideoOnlyRenditionAtTargetSize() async throws {
        let source = root.appendingPathComponent("source.mp4")
        try await SyntheticVideo.write(
            to: source, size: CGSize(width: 1280, height: 720), frameRate: 60, frameCount: 90, includeAudio: true
        )
        let progress = ProgressLog()

        let rendition = try await VideoAssetOptimizer(storage: storage).optimize(
            sourceURL: source,
            assetID: UUID(),
            maximumPixelSize: CGSize(width: 640, height: 360),
            quality: .efficiency,
            progress: { progress.append($0) }
        )

        XCTAssertFalse(rendition.isPassthrough)
        XCTAssertEqual(rendition.codecType, "HEVC")
        XCTAssertEqual(rendition.pixelSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(rendition.frameRate, 30, accuracy: 1)
        XCTAssertEqual(rendition.duration, 1.5, accuracy: 0.15)
        XCTAssertEqual(rendition.targetPixelSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(rendition.frameRateCap, 30)
        XCTAssertEqual(rendition.bitDepth, 8)
        XCTAssertFalse(rendition.isHDR)

        // Verify the file itself, not just the returned record.
        let output = AVURLAsset(url: storage.url(forRelativePath: rendition.relativePath))
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty, "audio must be dropped")
        let track = try XCTUnwrap(videoTracks.first)
        let (naturalSize, formats, duration) = try await (track.load(.naturalSize), track.load(.formatDescriptions), output.load(.duration))
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_HEVC)
        XCTAssertEqual(duration.seconds, 1.5, accuracy: 0.15)

        XCTAssertEqual(try optimizedFiles(), [URL(fileURLWithPath: rendition.relativePath).lastPathComponent], "no partial file remains")
        let values = progress.values
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress never goes backwards")
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
    }

    func testSuitableSourceIsCopiedWithoutReencoding() async throws {
        let source = root.appendingPathComponent("source.mp4")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 640, height: 360), frameCount: 60, includeAudio: true)
        let sourceTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)
        let sourceRate = try await XCTUnwrap(sourceTracks.first).load(.estimatedDataRate)

        let rendition = try await VideoAssetOptimizer(storage: storage).optimize(
            sourceURL: source,
            assetID: UUID(),
            maximumPixelSize: CGSize(width: 3840, height: 2160),
            quality: .efficiency
        )

        XCTAssertTrue(rendition.isPassthrough)
        XCTAssertEqual(rendition.codecType, "H264")
        XCTAssertEqual(rendition.pixelSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(rendition.duration, 2, accuracy: 0.1)

        let output = AVURLAsset(url: storage.url(forRelativePath: rendition.relativePath))
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let outputTracks = try await output.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(outputTracks.first)
        let (formats, outputRate) = try await (track.load(.formatDescriptions), track.load(.estimatedDataRate))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        XCTAssertEqual(Double(outputRate), Double(sourceRate), accuracy: Double(sourceRate) * 0.05, "the same compressed samples")

        // The copy lives in the app's container, independent of the original.
        try FileManager.default.removeItem(at: source)
        let isPlayable = try await output.load(.isPlayable)
        XCTAssertTrue(isPlayable)
    }

    func testCancellationLeavesNoFiles() async throws {
        let source = root.appendingPathComponent("long.mp4")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 1920, height: 1080), frameRate: 60, frameCount: 600)
        let optimizer = VideoAssetOptimizer(storage: storage)
        let storage = self.storage!

        let task = Task {
            try await optimizer.optimize(
                sourceURL: source,
                assetID: UUID(),
                maximumPixelSize: CGSize(width: 1280, height: 720),
                quality: .efficiency
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            // Finishing before the cancel lands is legitimate on a fast Mac.
        } catch is CancellationError {
            let files = try FileManager.default.contentsOfDirectory(atPath: storage.optimizedDirectory.path)
            XCTAssertTrue(files.isEmpty, "a cancelled import must leave nothing behind: \(files)")
        }
    }

    func testFailureLeavesNoFiles() async throws {
        let bogus = root.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: bogus)

        do {
            _ = try await VideoAssetOptimizer(storage: storage).optimize(
                sourceURL: bogus, assetID: UUID(), maximumPixelSize: CGSize(width: 1280, height: 720), quality: .efficiency
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(try optimizedFiles().isEmpty)
        }
    }

    func testPostersAreWrittenAsHEICWithThumbnailAndOldPNGStillLoads() async throws {
        let source = root.appendingPathComponent("source.mp4")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 1280, height: 720), frameCount: 10)
        let store = PosterCacheStore(storage: storage)
        let assetID = UUID()

        let poster = try await PosterFrameGenerator().generatePosterBox(for: source, maxPixelSize: CGSize(width: 1280, height: 720))
        let stored = try await store.savePoster(poster, for: assetID)

        XCTAssertEqual(stored.posterPath, "Posters/\(assetID.uuidString).heic")
        XCTAssertEqual(stored.thumbnailPath, "Posters/\(assetID.uuidString)-thumb.heic")
        let thumbnailSource = try XCTUnwrap(CGImageSourceCreateWithURL(storage.url(forRelativePath: try XCTUnwrap(stored.thumbnailPath)) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(thumbnailSource) as String?, "public.heic")
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(thumbnailSource, 0, nil))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 480)

        let reloaded = await PosterCacheStore(storage: storage).loadPoster(relativePath: stored.posterPath)
        XCTAssertEqual(reloaded?.image.width, 1280)

        // A poster written as PNG by a previous version keeps loading.
        let legacyPath = "Posters/legacy.png"
        try PosterCacheStore.write(poster.image, to: storage.url(forRelativePath: legacyPath), type: .png)
        let legacy = await PosterCacheStore(storage: storage).loadPoster(relativePath: legacyPath)
        XCTAssertEqual(legacy?.image.width, 1280)
    }
}
