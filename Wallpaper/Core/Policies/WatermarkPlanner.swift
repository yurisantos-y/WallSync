import CoreGraphics
import Foundation

/// How a marked logo is removed, from the most faithful to the least.
enum WatermarkStrategy: String, Codable, Sendable, CaseIterable {
    /// The mark is pushed out of the frame; no pixel is invented.
    case reframe
    /// A translucent mark is un-mixed: the original pixels are recovered.
    case unblend
    /// The area is filled with real content from neighbouring frames.
    case temporal
    /// The area is filled from its surroundings.
    case spatial
}

/// Decisions of the logo remover that need no pixels.
enum WatermarkPlanner {
    struct Reframe: Equatable, Sendable {
        /// Visible part of the picture, unit rectangle with a top-left
        /// origin, same proportions as the video.
        var crop: CGRect
        /// Share of the picture that is lost, 0 … 1.
        var areaLoss: Double
    }

    /// Reframing is offered only while it costs little of the picture.
    static let maximumReframeAreaLoss = 0.15

    /// The largest crop with the video's proportions that leaves every
    /// marked region outside, anchored to one of the four corners (logos
    /// sit near edges). `nil` when that would cost too much of the picture.
    static func reframe(excluding regions: [CGRect], maximumAreaLoss: Double = maximumReframeAreaLoss) -> Reframe? {
        guard !regions.isEmpty else { return nil }

        // A crop of side `s` (in unit coordinates, so the proportions are
        // kept) anchored at a corner excludes a region when the region
        // starts beyond `s` on at least one axis, measured from that corner.
        func side(_ distances: (CGRect) -> (CGFloat, CGFloat)) -> CGFloat {
            regions.map { region in
                let (horizontal, vertical) = distances(region)
                return max(horizontal, vertical)
            }.min() ?? 0
        }

        let candidates: [(side: CGFloat, origin: (CGFloat) -> CGPoint)] = [
            (side { ($0.minX, $0.minY) }, { _ in CGPoint(x: 0, y: 0) }),
            (side { (1 - $0.maxX, $0.minY) }, { CGPoint(x: 1 - $0, y: 0) }),
            (side { ($0.minX, 1 - $0.maxY) }, { CGPoint(x: 0, y: 1 - $0) }),
            (side { (1 - $0.maxX, 1 - $0.maxY) }, { CGPoint(x: 1 - $0, y: 1 - $0) })
        ]
        guard let best = candidates.max(by: { $0.side < $1.side }), best.side > 0 else { return nil }

        let side = min(best.side, 1)
        let areaLoss = Double(1 - side * side)
        guard areaLoss <= maximumAreaLoss else { return nil }
        return Reframe(crop: CGRect(origin: best.origin(side), size: CGSize(width: side, height: side)), areaLoss: areaLoss)
    }

    /// Whether filling the screen already cuts the region off on every one
    /// of the given displays, in which case nothing needs to be removed.
    static func isCroppedOut(region: CGRect, videoSize: CGSize, displaySizes: [CGSize]) -> Bool {
        guard !displaySizes.isEmpty, videoSize.width > 0, videoSize.height > 0 else { return false }
        return displaySizes.allSatisfy { display in
            guard display.width > 0, display.height > 0 else { return false }
            let scale = max(display.width / videoSize.width, display.height / videoSize.height)
            let visible = CGSize(width: display.width / scale / videoSize.width, height: display.height / scale / videoSize.height)
            let visibleRect = CGRect(
                x: (1 - visible.width) / 2, y: (1 - visible.height) / 2, width: visible.width, height: visible.height
            )
            return !visibleRect.intersects(region)
        }
    }

    /// What the analysis of a region found.
    struct RegionAnalysis: Equatable, Sendable {
        /// Share of the marked pixels whose mix with the background could
        /// be measured reliably (a translucent mark).
        var translucentFraction: Double
        /// Share of the region that is marked at all.
        var markedFraction: Double
    }

    /// Un-mixing is used when nearly all of the mark is measurably
    /// translucent; opaque parts of such a mark are filled individually.
    static let minimumTranslucentFraction = 0.7

    /// Strategy for a region before frames are processed. Filling from
    /// neighbouring frames is decided frame by frame, when the scene moves
    /// far enough to uncover what is behind the mark; `spatial` here means
    /// "fill, with real content whenever it is available".
    static func strategy(for analysis: RegionAnalysis) -> WatermarkStrategy {
        analysis.markedFraction > 0.002 && analysis.translucentFraction >= minimumTranslucentFraction ? .unblend : .spatial
    }
}
