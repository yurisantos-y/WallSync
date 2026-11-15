import AVFoundation
import XCTest
@testable import WallSync

/// A surface backed by a real `WallpaperHostView`, without a window.
@MainActor
private final class HostingSurface: WallpaperSurface, VideoFrameHosting {
    let hostView = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    private(set) var displayTarget: DisplayTarget
    var isOccluded = false
    var onOcclusionChange: (() -> Void)?

    init(_ uuid: String) { displayTarget = Fixture.display(uuid) }

    func update(displayTarget: DisplayTarget) { self.displayTarget = displayTarget }
    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) { hostView.setContentMode(contentMode) }
    func setPoster(_ image: CGImage?) { hostView.setPoster(image) }
    func showPoster() { hostView.setVideoVisible(false) }
    func showVideo() { hostView.setVideoVisible(true) }
    func show() {}
    func hide() {}
    func close() {}
}

/// Exercises the real AVFoundation pipeline with a clip generated at test
/// time. Set `TEST_RUNNER_SKIP_MEDIA_TESTS=1` to skip on machines without a
/// working media stack.
@MainActor
final class PlaybackEngineTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_MEDIA_TESTS"] != nil, "media pipeline tests disabled by SKIP_MEDIA_TESTS")
        directory = try Fixture.temporaryDirectory()
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeClip(includeAudio: Bool = true) async throws -> URL {
        let url = directory.appendingPathComponent("clip.mp4")
        try await SyntheticVideo.write(to: url, frameCount: 30, includeAudio: includeAudio)
        return url
    }

    /// Pumps frames until `condition` holds. Deadlines are generous because
    /// the suite runs in parallel with CPU-heavy transcoding tests.
    @discardableResult
    private func pump(
        _ engine: AVPlayerPlaybackEngine,
        timeout: Duration = .seconds(8),
        until condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            engine.pumpFrame(hostTime: CACurrentMediaTime())
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(8))
        }
        return condition()
    }

    private func pump(_ engine: AVPlayerPlaybackEngine, for duration: Duration) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            engine.pumpFrame(hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    func testAudioIsNeverHandedToThePlayer() async throws {
        let clip = try await makeClip(includeAudio: true)
        let source = AVURLAsset(url: clip)
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceAudio.count, 1, "the fixture must contain audio for this test to mean anything")

        let engine = AVPlayerPlaybackEngine()
        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }

        let loaded = try XCTUnwrap(engine.loadedAsset)
        let audio = try await loaded.loadTracks(withMediaType: .audio)
        let video = try await loaded.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(video.count, 1)
    }

    func testOneDecodeFeedsEveryDisplayWithTheSameFrame() async throws {
        let clip = try await makeClip()
        let engine = AVPlayerPlaybackEngine()
        let first = HostingSurface("a")
        let second = HostingSurface("b")
        let third = HostingSurface("c")

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        [first, second, third].forEach(engine.attach)
        engine.setPlaying(true)

        try await pump(engine) { engine.presentedFrameCount > 5 }

        XCTAssertGreaterThan(engine.presentedFrameCount, 5)
        let frames = [first, second, third].map { $0.hostView.presentedFrameContents as AnyObject? }
        XCTAssertNotNil(frames[0])
        XCTAssertTrue(frames[0] === frames[1], "displays show the very same decoded surface: no copy, no drift")
        XCTAssertTrue(frames[1] === frames[2])
        XCTAssertNil(first.hostView.playerLayer.player, "shared frames replaced the direct player layer")
    }

    func testLoopKeepsProducingFramesPastTheEndOfTheClip() async throws {
        let clip = try await makeClip() // one second long
        let engine = AVPlayerPlaybackEngine()
        let surfaces = [HostingSurface("a"), HostingSurface("b")]

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        surfaces.forEach(engine.attach)
        engine.setPlaying(true)

        // The clip has 30 frames; reaching well beyond that means the loop
        // wrapped around and kept delivering frames.
        let wrapped = try await pump(engine) { engine.presentedFrameCount > 50 }

        XCTAssertTrue(wrapped, "frames must keep arriving after the loop point (got \(engine.presentedFrameCount))")
        XCTAssertLessThan(engine.currentTime, 1.05)
    }

    func testFrozenDisplayKeepsItsFrameWhileOthersAdvance() async throws {
        let clip = try await makeClip()
        let engine = AVPlayerPlaybackEngine()
        let live = HostingSurface("a")
        let frozen = HostingSurface("b")

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        engine.attach(live)
        engine.attach(frozen)
        engine.setPlaying(true)
        try await pump(engine) { engine.presentedFrameCount > 2 }

        engine.setLive(false, for: frozen)
        let held = try XCTUnwrap(frozen.hostView.presentedFrameContents as AnyObject?)
        let framesAtFreeze = engine.presentedFrameCount
        try await pump(engine) { engine.presentedFrameCount > framesAtFreeze + 5 }

        XCTAssertGreaterThan(engine.presentedFrameCount, framesAtFreeze + 5)
        XCTAssertTrue((frozen.hostView.presentedFrameContents as AnyObject?) === held)
        XCTAssertFalse((live.hostView.presentedFrameContents as AnyObject?) === held)
    }

    func testSingleDisplayUsesDirectPlayerLayer() async throws {
        let clip = try await makeClip()
        let engine = AVPlayerPlaybackEngine()
        let only = HostingSurface("a")

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        engine.attach(only)
        engine.setPlaying(true)
        try await pump(engine, for: .milliseconds(300))

        XCTAssertNotNil(only.hostView.playerLayer.player)
        XCTAssertEqual(engine.presentedFrameCount, 0, "no frame distribution work for a single display")

        engine.detach(only)
        XCTAssertNil(only.hostView.playerLayer.player)
    }

    func testPausedEngineDeliversNoFrames() async throws {
        let clip = try await makeClip()
        let engine = AVPlayerPlaybackEngine()
        let surfaces = [HostingSurface("a"), HostingSurface("b")]

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        surfaces.forEach(engine.attach)
        engine.setPlaying(true)
        try await pump(engine) { engine.presentedFrameCount > 2 }

        engine.setPlaying(false)
        try await pump(engine, for: .milliseconds(200))
        let whilePaused = engine.presentedFrameCount
        let position = engine.currentTime
        try await pump(engine, for: .milliseconds(400))

        XCTAssertEqual(engine.presentedFrameCount, whilePaused, "no frame is decoded while paused")
        XCTAssertEqual(engine.currentTime, position, accuracy: 0.001)
    }

    func testUnplayableFileThrowsAndLeavesEngineEmpty() async throws {
        let bogus = directory.appendingPathComponent("not-a-video.mp4")
        try Data("nope".utf8).write(to: bogus)
        let engine = AVPlayerPlaybackEngine()

        do {
            try await engine.prepare(url: bogus, maximumPixelSize: nil, startTime: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertNil(engine.loadedAsset)
        }
    }

    func testFailedSwapKeepsCurrentPlayback() async throws {
        let clip = try await makeClip()
        let bogus = directory.appendingPathComponent("broken.mp4")
        try Data("nope".utf8).write(to: bogus)
        let engine = AVPlayerPlaybackEngine()

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        let loaded = engine.loadedAsset

        do {
            try await engine.prepare(url: bogus, maximumPixelSize: nil, startTime: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(engine.loadedAsset === loaded)
        }
    }

    // MARK: - Playback speed

    func testDisplayLinkWakesAtTheEffectiveFrameRate() async throws {
        let clip = try await makeClip() // 30 fps
        let engine = AVPlayerPlaybackEngine()
        let surfaces = [HostingSurface("a"), HostingSurface("b")]

        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        surfaces.forEach(engine.attach)
        engine.setPlaying(true)

        XCTAssertEqual(engine.displayLinkFrameRate, 30, "full speed wakes once per video frame")

        engine.setPlaybackRate(0.5)
        XCTAssertEqual(engine.effectiveFrameRate, 15, accuracy: 0.01)
        XCTAssertEqual(engine.displayLinkFrameRate, 15, "half speed halves the wake-ups")

        engine.setPlaybackRate(0.25)
        XCTAssertEqual(engine.displayLinkFrameRate, 8, "7.5 frames per second, rounded up")

        engine.setPlaybackRate(4)
        XCTAssertEqual(engine.displayLinkFrameRate, 30, "speeds above 1x are not available")

        engine.setPlaying(false)
        XCTAssertNil(engine.displayLinkFrameRate, "no wake-ups at all while paused")
    }

    func testHalfSpeedDecodesHalfTheFrames() async throws {
        let clip = try await makeClip()

        func framesPresented(rate: Double) async throws -> Int {
            let engine = AVPlayerPlaybackEngine()
            let surfaces = [HostingSurface("a"), HostingSurface("b")]
            engine.setPlaybackRate(rate)
            try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
            defer { engine.teardown() }
            surfaces.forEach(engine.attach)
            engine.setPlaying(true)
            try await pump(engine) { engine.presentedFrameCount > 0 }
            let start = engine.presentedFrameCount
            try await pump(engine, for: .seconds(2))
            return engine.presentedFrameCount - start
        }

        // The suite runs next to CPU-heavy transcoding tests, which can
        // starve the pump for a moment; a measurement disturbed that way is
        // repeated rather than trusted.
        var measurements: [String] = []
        for _ in 0..<4 {
            let full = try await framesPresented(rate: 1)
            let half = try await framesPresented(rate: 0.5)
            measurements.append("full=\(full) half=\(half)")
            if full > 30, abs(Double(half) / Double(full) - 0.5) <= 0.15 {
                return
            }
        }
        XCTFail("half speed should present about half the frames: \(measurements)")
    }

    func testSpeedSurvivesPauseAndResume() async throws {
        let clip = try await makeClip()
        let engine = AVPlayerPlaybackEngine()
        let surface = HostingSurface("a")
        engine.setPlaybackRate(0.5)
        try await engine.prepare(url: clip, maximumPixelSize: nil, startTime: 0)
        defer { engine.teardown() }
        engine.attach(surface)

        engine.setPlaying(true)
        XCTAssertEqual(surface.hostView.playerLayer.player?.rate, 0.5)
        engine.setPlaying(false)
        XCTAssertEqual(surface.hostView.playerLayer.player?.rate, 0)
        engine.setPlaying(true)
        XCTAssertEqual(surface.hostView.playerLayer.player?.rate, 0.5)
        engine.setPlaybackRate(1)
        XCTAssertEqual(surface.hostView.playerLayer.player?.rate, 1, "the change is immediate")
    }
}
