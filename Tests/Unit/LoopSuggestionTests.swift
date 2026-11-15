import AVFoundation
import XCTest
@testable import WallSync

final class LoopPointScorerTests: XCTestCase {
    /// A picture whose content depends only on `phase` (0 … 1): a bright
    /// column whose position follows the phase.
    private func frame(phase: Double, width: Int = 24, height: Int = 4) -> [Float] {
        var pixels = [Float](repeating: 0.1, count: width * height)
        let position = phase * Double(width - 1)
        for y in 0..<height {
            for x in 0..<width {
                let distance = abs(Double(x) - position)
                pixels[y * width + x] = Float(max(0.1, 1 - distance / 3))
            }
        }
        return pixels
    }

    private func samples(_ times: [Double], phase: (Double) -> Double) -> [LoopFrameSample] {
        times.map { LoopFrameSample(time: $0, pixels: frame(phase: phase($0))) }
    }

    func testPeriodicMotionLoopsOnAWholeNumberOfPeriods() throws {
        // Sawtooth with a 4 s period in a 10 s video: 0 → 8 is two periods.
        let phase: (Double) -> Double = { ($0.truncatingRemainder(dividingBy: 4)) / 4 }
        let head = samples(stride(from: 0.0, through: 3.0, by: 0.25).map { $0 }, phase: phase)
        let tail = samples(stride(from: 7.0, through: 10.0, by: 0.25).map { $0 }, phase: phase)

        let suggestion = try XCTUnwrap(LoopPointScorer.suggest(head: head, tail: tail, duration: 10, minimumLength: 3))
        let length = suggestion.end - suggestion.start
        XCTAssertEqual(length.truncatingRemainder(dividingBy: 4), 0, accuracy: 1e-9, "length \(length) is not a whole number of periods")
        XCTAssertEqual(length, 8, "the longest matching loop is preferred")
        XCTAssertLessThan(suggestion.mismatch, 0.001)
        XCTAssertEqual(suggestion.crossfade, 0, "matching frames need no dissolve")
    }

    func testSameFrameMovingTheOtherWayIsNotAGoodLoopPoint() throws {
        // A pendulum: the column goes right for 2 s, then back for 2 s.
        // At 0.5 s and at 3.5 s the picture is identical but moving in
        // opposite directions; 0.5 s and 4.5 s match in both.
        let phase: (Double) -> Double = { time in
            let t = time.truncatingRemainder(dividingBy: 4)
            return (t < 2 ? t : 4 - t) / 2
        }
        let head = samples([0.25, 0.5, 0.75], phase: phase)
        let tail = samples(stride(from: 3.0, through: 5.0, by: 0.25).map { $0 }, phase: phase)

        let identicalButOpposite = samples([3.5], phase: phase)[0]
        XCTAssertEqual(LoopPointScorer.difference(head[1].pixels, identicalButOpposite.pixels), 0, accuracy: 1e-6, "the two frames really are identical")

        let suggestion = try XCTUnwrap(LoopPointScorer.suggest(head: head, tail: tail, duration: 6, minimumLength: 1))
        XCTAssertEqual(suggestion.end - suggestion.start, 4, "one full swing: the match with motion in the same direction wins")
        XCTAssertLessThan(suggestion.mismatch, 0.001)
    }

    func testMismatchAsksForACrossfadeBoundedByTheLoopLength() {
        XCTAssertEqual(LoopPointScorer.suggestedCrossfade(mismatch: 0, length: 10), 0)
        XCTAssertGreaterThan(LoopPointScorer.suggestedCrossfade(mismatch: 0.05, length: 10), 0.5)
        XCTAssertLessThanOrEqual(LoopPointScorer.suggestedCrossfade(mismatch: 1, length: 10), 1.5)
        XCTAssertLessThanOrEqual(LoopPointScorer.suggestedCrossfade(mismatch: 1, length: 2), 0.5)
    }

    func testTooFewSamplesOrTooShortGiveNoSuggestion() {
        let one = samples([0], phase: { _ in 0 })
        XCTAssertNil(LoopPointScorer.suggest(head: one, tail: one, duration: 5, minimumLength: 1))
        let head = samples([0, 0.5], phase: { _ in 0 })
        let tail = samples([1, 1.5], phase: { _ in 0 })
        XCTAssertNil(LoopPointScorer.suggest(head: head, tail: tail, duration: 5, minimumLength: 4))
    }
}

final class LoopPointAnalyzerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_MEDIA_TESTS"] != nil, "media pipeline tests disabled by SKIP_MEDIA_TESTS")
        root = try Fixture.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSuggestionOnARealFileFindsThePeriod() async throws {
        // 6 s at 20 fps; a bright band sweeps across every 2.5 s (50 frames).
        let url = root.appendingPathComponent("periodic.mp4")
        try await FrameFactory.writeClip(to: url, frameCount: 120, frameRate: 20) { index in
            let position = (index % 50) * 6
            return FrameFactory.buffer(width: 320, height: 180, tenBit: false, luma: { x, _ in abs(x - position) < 24 ? 220 : 40 })
        }

        let found = try await LoopPointAnalyzer.suggest(url: url)
        let suggestion = try XCTUnwrap(found)
        let length = suggestion.end - suggestion.start
        let periods = length / 2.5
        XCTAssertEqual(periods, periods.rounded(), accuracy: 0.08, "length \(length) s should be a whole number of 2.5 s periods")
        XCTAssertGreaterThanOrEqual(length, 2.4)
        XCTAssertLessThan(suggestion.mismatch, 0.03)
    }

    func testPreviewTimelineMatchesTheOptimizerTimeline() async throws {
        let url = root.appendingPathComponent("clip.mp4")
        try await FrameFactory.writeClip(to: url, frameCount: 90) { index in
            FrameFactory.buffer(width: 320, height: 180, tenBit: false, luma: { _, _ in 40 + 2 * index })
        }
        var recipe = EditRecipe()
        recipe.trim = .init(start: 0.5, end: 2.5)
        recipe.loopCrossfade = 0.5

        let preview = try await LoopPreviewBuilder.make(asset: AVURLAsset(url: url), recipe: recipe)
        XCTAssertEqual(preview.duration, 1.5, accuracy: 1e-6)
        XCTAssertEqual(preview.composition.duration.seconds, 1.5, accuracy: 0.01)
        XCTAssertEqual(preview.composition.tracks(withMediaType: .video).count, 2, "main track and the head that fades in")
        XCTAssertNotNil(preview.videoComposition)

        let plain = try await LoopPreviewBuilder.make(asset: AVURLAsset(url: url), recipe: .empty)
        XCTAssertNil(plain.videoComposition, "no dissolve, no real-time composition")
        XCTAssertEqual(plain.duration, 3, accuracy: 0.01)
    }
}
