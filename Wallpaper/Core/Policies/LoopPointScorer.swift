import Foundation

/// A small greyscale picture of one frame, values 0 … 1.
struct LoopFrameSample: Sendable {
    var time: TimeInterval
    var pixels: [Float]
}

struct LoopSuggestion: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    /// Dissolve that hides what difference is left; 0 when the frames match.
    var crossfade: TimeInterval
    /// Mean absolute difference between the frame the loop starts on and
    /// the frame that would have followed its end, 0 … 1.
    var mismatch: Double
}

/// Picks where a video should start and end so that it repeats smoothly.
///
/// A loop that ends just before time `e` and restarts at time `s` is smooth
/// when the frame at `s` looks like the frame at `e` — the one that would
/// have come next — *and* the picture is moving the same way at both points.
/// Two identical frames with motion in opposite directions (a pendulum
/// passing the same spot on its way back) still produce a visible jerk, so
/// the frame-to-frame change is compared as well: the change leading into
/// `e` against the change leading into `s`, and the change leaving `e`
/// against the change leaving `s`.
enum LoopPointScorer {
    static let motionWeight = 2.0
    /// Slight preference for keeping more of the video.
    static let lengthBonus = 0.01

    /// - Parameters:
    ///   - head: evenly spaced samples from the beginning of the video.
    ///   - tail: evenly spaced samples from the end, same spacing.
    static func suggest(
        head: [LoopFrameSample],
        tail: [LoopFrameSample],
        duration: TimeInterval,
        minimumLength: TimeInterval
    ) -> LoopSuggestion? {
        guard head.count >= 2, tail.count >= 2, duration > 0 else { return nil }

        var best: (cost: Double, start: Int, end: Int, mismatch: Double)?
        for startIndex in head.indices {
            for endIndex in tail.indices {
                let length = tail[endIndex].time - head[startIndex].time
                guard length >= minimumLength else { continue }

                // Motion on each side of the two points, where a neighbour
                // exists on both.
                var motions: [Double] = []
                if startIndex > 0, endIndex > 0 {
                    motions.append(motionDifference(
                        head[startIndex - 1].pixels, head[startIndex].pixels,
                        tail[endIndex - 1].pixels, tail[endIndex].pixels
                    ))
                }
                if startIndex < head.count - 1, endIndex < tail.count - 1 {
                    motions.append(motionDifference(
                        head[startIndex].pixels, head[startIndex + 1].pixels,
                        tail[endIndex].pixels, tail[endIndex + 1].pixels
                    ))
                }
                guard !motions.isEmpty else { continue }

                let mismatch = difference(head[startIndex].pixels, tail[endIndex].pixels)
                let motion = motions.reduce(0, +) / Double(motions.count)
                let cost = mismatch + motionWeight * motion - lengthBonus * (length / duration)
                if best == nil || cost < best!.cost {
                    best = (cost, startIndex, endIndex, mismatch)
                }
            }
        }

        guard let best else { return nil }
        let start = head[best.start].time
        let end = min(tail[best.end].time, duration)
        return LoopSuggestion(
            start: start,
            end: end,
            crossfade: suggestedCrossfade(mismatch: best.mismatch, length: end - start),
            mismatch: best.mismatch
        )
    }

    /// No dissolve for frames that already match; up to 1.5 s otherwise,
    /// never more than a quarter of the loop.
    static func suggestedCrossfade(mismatch: Double, length: TimeInterval) -> TimeInterval {
        guard mismatch > 0.008 else { return 0 }
        let wanted = min(1.5, 0.4 + mismatch * 12)
        return (min(wanted, length / 4) * 10).rounded() / 10
    }

    static func difference(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total: Float = 0
        for index in a.indices {
            total += abs(a[index] - b[index])
        }
        return Double(total) / Double(a.count)
    }

    /// Difference between the change `a0 → a1` and the change `b0 → b1`.
    private static func motionDifference(_ a0: [Float], _ a1: [Float], _ b0: [Float], _ b1: [Float]) -> Double {
        guard a0.count == a1.count, a0.count == b0.count, a0.count == b1.count, !a0.isEmpty else { return 1 }
        var total: Float = 0
        for index in a0.indices {
            total += abs((a1[index] - a0[index]) - (b1[index] - b0[index]))
        }
        return Double(total) / Double(a0.count)
    }
}
