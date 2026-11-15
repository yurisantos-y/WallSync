import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Removes fixed logos from the frames of a video, inside the optimizer.
///
/// Per marked region, in order of fidelity (reframing, the lossless option,
/// is a crop and happens before frames get here):
///
/// * **Un-mixing** when the analysis shows a translucent mark: the measured
///   opacity and colour are inverted per pixel (`BlendEstimator`).
/// * **Real content from neighbouring frames** when the scene moves: the
///   motion between frames is estimated on small versions of the frames and
///   then locked, to the pixel, on the band around the mark; a neighbour is
///   used only if it shows the whole area clear of its own mark and its
///   surroundings match the current frame's.
/// * **A fill from the surroundings** otherwise (`SpatialFill`).
///
/// The pixel work runs on the GPU in the frames' native format
/// (`PlaneProcessor.removeMark`); everything outside the regions is copied
/// bit for bit.
final class WatermarkRemover {
    /// What the analysis decided for one region.
    struct RegionPlan {
        /// The mark in luma pixels of the output frame; even origin and size.
        var rect: PixelRect
        /// `.unblend` or `.spatial` ("fill, from neighbours when possible").
        var strategy: WatermarkStrategy
        var maps: [PlaneProcessor.BlendMaps]?
        var analysis: WatermarkPlanner.RegionAnalysis
    }

    private struct Entry {
        var index: Int
        /// Scene position, accumulated frame to frame, in luma pixels.
        var position: SIMD2<Float>
        var crops: [RegionCrop]
    }

    private struct RegionCrop {
        var crop: PixelRect
        var planes: [Data]
        var luma: PlaneImage
    }

    private let processor: PlaneProcessor
    private let plans: [RegionPlan]
    private let window: Int
    private let lookahead: Int

    private var pending: [(frame: CVPixelBuffer, time: CMTime, index: Int)] = []
    private var entries: [Entry] = []
    private var previousThumbnail: PlaneImage?
    private var position = SIMD2<Float>(0, 0)
    private var nextIndex = 0
    private var reachedEnd = false
    private var frameWidth = WatermarkRemover.thumbnailWidth

    /// Per region, whether each frame could be filled from neighbours:
    /// measured for frames already written, estimated from the motion alone
    /// for the frames held ahead.
    private var availability: [[Int: Bool]]

    /// Frames over which the fill eases between "from neighbouring frames"
    /// and "from the surroundings" when neighbours stop or start being
    /// usable, so the change is a slow dissolve and never a visible switch.
    static let easeFrames = 10

    /// Frames in which each region was filled from neighbouring frames.
    private(set) var temporalFrames: [Int]
    private(set) var processedFrames = 0
    /// Share of the fill taken from neighbouring frames, per region and
    /// frame; kept for diagnostics and tests.
    private(set) var mixHistory: [[Float]] = []

    /// A neighbour's surroundings must match this closely (0 … 1).
    static let maximumMatchError: Float = 0.02
    static let thumbnailWidth = 160

    /// - Parameters:
    ///   - frameRate: used to size the window of neighbouring frames.
    ///   - frameBytes: size of one frame; bounds how many are held ahead.
    init(processor: PlaneProcessor, plans: [RegionPlan], frameRate: Double, frameBytes: Int) {
        self.processor = processor
        self.plans = plans
        temporalFrames = [Int](repeating: 0, count: plans.count)
        availability = [[Int: Bool]](repeating: [:], count: plans.count)
        // Two seconds of neighbours behind; ahead, as many frames as fit in
        // about 200 MB (whole frames have to be held until they are written).
        window = max(8, Int((frameRate * 2).rounded()))
        lookahead = max(2, min(Int(frameRate.rounded()), 200_000_000 / max(frameBytes, 1)))
    }

    /// The strategy that was actually used for each region.
    var usedStrategies: [WatermarkStrategy] {
        plans.enumerated().map { index, plan in
            if plan.strategy == .unblend { return .unblend }
            return processedFrames > 0 && temporalFrames[index] * 2 >= processedFrames ? .temporal : .spatial
        }
    }

    // MARK: - Stream

    func push(_ frame: CVPixelBuffer, time: CMTime) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        frameWidth = width

        // Motion since the previous frame, on a small version of the picture.
        let scale = max(1, width / Self.thumbnailWidth)
        let thumbnail = Self.thumbnail(of: frame, scale: scale)
        if let previousThumbnail {
            let excluded = plans.map { plan in
                PixelRect(
                    x: plan.rect.x / scale - 1, y: plan.rect.y / scale - 1,
                    width: plan.rect.width / scale + 2, height: plan.rect.height / scale + 2
                )
            }
            let shift = MotionSearch.coarse(from: previousThumbnail, to: thumbnail, radius: 10, exclude: excluded)
            position += SIMD2(shift.dx, shift.dy) * Float(scale)
        }
        previousThumbnail = thumbnail

        let crops = plans.map { plan -> RegionCrop in
            let crop = Self.cropRect(for: plan.rect, width: width, height: height)
            return RegionCrop(
                crop: crop,
                planes: [
                    PlaneProcessor.copyPlane(of: frame, plane: 0, rect: crop),
                    PlaneProcessor.copyPlane(
                        of: frame, plane: 1,
                        rect: PixelRect(x: crop.x / 2, y: crop.y / 2, width: crop.width / 2, height: crop.height / 2)
                    )
                ],
                luma: PlaneProcessor.planeImage(of: frame, plane: 0, rect: crop)
            )
        }

        entries.append(Entry(index: nextIndex, position: position, crops: crops))
        pending.append((frame, time, nextIndex))
        nextIndex += 1
    }

    func finish() {
        reachedEnd = true
    }

    /// The next finished frame, or `nil` when more input is needed first.
    func pop() throws -> (frame: CVPixelBuffer, time: CMTime)? {
        guard let first = pending.first, reachedEnd || pending.count > lookahead else { return nil }
        pending.removeFirst()

        var frame = first.frame
        for (regionIndex, plan) in plans.enumerated() {
            let candidates = self.candidates(for: regionIndex, frameIndex: first.index)
            availability[regionIndex][first.index] = !candidates.isEmpty
            if !candidates.isEmpty { temporalFrames[regionIndex] += 1 }
            let mix = temporalMix(for: regionIndex, frameIndex: first.index)
            if mixHistory.count <= regionIndex { mixHistory.append([]) }
            mixHistory[regionIndex].append(mix)
            frame = try processor.removeMark(
                in: frame,
                job: PlaneProcessor.MarkJob(rect: plan.rect, maps: plan.maps, candidates: candidates, temporalMix: mix)
            )
        }
        processedFrames += 1

        // Neighbours older than the window are no longer needed.
        entries.removeAll { $0.index < first.index - window }
        for regionIndex in availability.indices {
            availability[regionIndex] = availability[regionIndex].filter { $0.key >= first.index - Self.easeFrames }
        }
        return (frame, first.time)
    }

    // MARK: - Neighbouring frames

    /// 1 when frames around this one can all be filled from neighbours,
    /// falling to 0 as a frame that cannot comes closer.
    private func temporalMix(for regionIndex: Int, frameIndex: Int) -> Float {
        guard availability[regionIndex][frameIndex] == true else { return 0 }
        var nearest = Self.easeFrames
        for distance in 1..<Self.easeFrames {
            for index in [frameIndex - distance, frameIndex + distance] {
                let known = availability[regionIndex][index] ?? estimatedAvailability(for: regionIndex, frameIndex: index)
                if known == false {
                    nearest = min(nearest, distance)
                }
            }
            if nearest < Self.easeFrames { break }
        }
        return Float(nearest) / Float(Self.easeFrames)
    }

    /// Whether a frame held ahead will probably find a neighbour, judged
    /// from the motion alone. `nil` for frames that are not known (before
    /// the start, after the end, beyond what is held).
    private func estimatedAvailability(for regionIndex: Int, frameIndex: Int) -> Bool? {
        guard let current = entries.first(where: { $0.index == frameIndex }) else { return nil }
        let rect = plans[regionIndex].rect
        let crop = current.crops[regionIndex].crop
        let local = PixelRect(x: rect.x - crop.x, y: rect.y - crop.y, width: rect.width, height: rect.height)
        let result = entries.contains { entry in
            guard entry.index != frameIndex else { return false }
            let delta = entry.position - current.position
            let dx = Int(delta.x.rounded()), dy = Int(delta.y.rounded())
            return MotionSearch.uncovers(rect: local, dx: dx, dy: dy)
                && local.x + dx >= 0 && local.y + dy >= 0
                && local.maxX + dx <= crop.width && local.maxY + dy <= crop.height
        }
        return result
    }

    private func candidates(for regionIndex: Int, frameIndex: Int) -> [PlaneProcessor.Candidate] {
        guard let current = entries.first(where: { $0.index == frameIndex }) else { return [] }
        let plan = plans[regionIndex]
        let currentCrop = current.crops[regionIndex]
        // The mark inside the crop.
        let local = PixelRect(
            x: plan.rect.x - currentCrop.crop.x, y: plan.rect.y - currentCrop.crop.y,
            width: plan.rect.width, height: plan.rect.height
        )
        // The coarse estimate is good to about one thumbnail pixel.
        let searchRadius = max(3, frameWidth / Self.thumbnailWidth + 2)

        func candidate(_ entry: Entry) -> PlaneProcessor.Candidate? {
            let delta = entry.position - current.position
            let initial = (dx: Int(delta.x.rounded()), dy: Int(delta.y.rounded()))
            // Far enough to uncover the area, near enough to be in the crop.
            guard MotionSearch.uncovers(rect: local, dx: initial.dx, dy: initial.dy, margin: 8 - searchRadius),
                  let refined = MotionSearch.refine(
                    current: currentCrop.luma, candidate: entry.crops[regionIndex].luma, rect: local,
                    around: initial, radius: searchRadius
                  ),
                  refined.error <= Self.maximumMatchError,
                  MotionSearch.uncovers(rect: local, dx: refined.dx, dy: refined.dy) else {
                return nil
            }
            let source = PixelRect(x: local.x + refined.dx, y: local.y + refined.dy, width: local.width, height: local.height)
            guard source.x >= 0, source.y >= 0, source.maxX <= currentCrop.crop.width, source.maxY <= currentCrop.crop.height else {
                return nil
            }
            return PlaneProcessor.Candidate(
                planes: entry.crops[regionIndex].planes,
                crop: entry.crops[regionIndex].crop,
                dx: refined.dx, dy: refined.dy,
                weight: 1 / Float(abs(entry.index - frameIndex))
            )
        }

        // The nearest usable frame before and the nearest after; a few
        // attempts per side keep the work bounded.
        var result: [PlaneProcessor.Candidate] = []
        for side in [entries.filter { $0.index < frameIndex }.reversed().map { $0 }, entries.filter { $0.index > frameIndex }] {
            var attempts = 0
            for entry in side where attempts < 8 {
                let delta = entry.position - current.position
                guard MotionSearch.uncovers(
                    rect: local, dx: Int(delta.x.rounded()), dy: Int(delta.y.rounded()), margin: 8 - searchRadius
                ) else { continue }
                attempts += 1
                if let found = candidate(entry) {
                    result.append(found)
                    break
                }
            }
        }
        return result
    }

    // MARK: - Geometry

    /// The mark with room around it for a neighbour shifted far enough to
    /// uncover it, on the even pixel grid.
    static func cropRect(for rect: PixelRect, width: Int, height: Int) -> PixelRect {
        let marginX = (rect.width + 56) / 2 * 2
        let marginY = (rect.height + 56) / 2 * 2
        let clipped = rect.insetBy(dx: -marginX, dy: -marginY).clipped(width: width / 2 * 2, height: height / 2 * 2)
        let x = (clipped.x + 1) / 2 * 2, y = (clipped.y + 1) / 2 * 2
        return PixelRect(x: x, y: y, width: (clipped.maxX - x) / 2 * 2, height: (clipped.maxY - y) / 2 * 2)
    }

    /// A unit rectangle (origin top-left) as an even pixel rectangle of a
    /// `width` × `height` frame, grown by a small safety border.
    static func pixelRect(for region: CGRect, width: Int, height: Int, border: Int = 2) -> PixelRect {
        let x0 = max(0, Int((region.minX * CGFloat(width)).rounded(.down)) - border) / 2 * 2
        let y0 = max(0, Int((region.minY * CGFloat(height)).rounded(.down)) - border) / 2 * 2
        let x1 = min(width / 2 * 2, (Int((region.maxX * CGFloat(width)).rounded(.up)) + border + 1) / 2 * 2)
        let y1 = min(height / 2 * 2, (Int((region.maxY * CGFloat(height)).rounded(.up)) + border + 1) / 2 * 2)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private static func thumbnail(of buffer: CVPixelBuffer, scale: Int) -> PlaneImage {
        let width = CVPixelBufferGetWidth(buffer) / scale, height = CVPixelBufferGetHeight(buffer) / scale
        let wide = (PlaneProcessor.planeFormat(of: buffer)?.levels ?? 0) > 0
        var image = PlaneImage(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return image }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        // A 2 x 2 average per sample is enough to tame noise and aliasing.
        let offsets = scale > 1 ? [0, scale / 2] : [0]
        for y in 0..<height {
            for x in 0..<width {
                var total: Float = 0
                for dy in offsets {
                    let line = base + (y * scale + dy) * rowBytes
                    for dx in offsets {
                        let index = x * scale + dx
                        total += wide
                            ? Float(line.load(fromByteOffset: index * 2, as: UInt16.self)) / 65535
                            : Float(line.load(fromByteOffset: index, as: UInt8.self)) / 255
                    }
                }
                image.pixels[y * width + x] = total / Float(offsets.count * offsets.count)
            }
        }
        return image
    }

    // MARK: - Analysis

    /// Decides the strategy for every region from frames sampled along the
    /// video, and measures the blend of translucent marks.
    static func plan(
        regions: [CGRect],
        samples: [CVPixelBuffer],
        processor: PlaneProcessor
    ) throws -> [RegionPlan] {
        guard let first = samples.first else { return [] }
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)

        return try regions.compactMap { region -> RegionPlan? in
            let rect = pixelRect(for: region, width: width, height: height)
            guard rect.width >= 2, rect.height >= 2 else { return nil }

            /// Observed pixels and predicted background of one plane
            /// component, over every sampled frame.
            func estimate(plane: Int, component: Int) -> BlendEstimator.Result {
                let divisor = plane == 0 ? 1 : 2
                let planeRect = PixelRect(x: rect.x / divisor, y: rect.y / divisor, width: rect.width / divisor, height: rect.height / divisor)
                let planeWidth = width / divisor, planeHeight = height / divisor
                // The region and enough of its surroundings for the border samples.
                let context = planeRect.insetBy(dx: -8, dy: -8).clipped(width: planeWidth, height: planeHeight)
                let local = PixelRect(x: planeRect.x - context.x, y: planeRect.y - context.y, width: planeRect.width, height: planeRect.height)

                var observed: [[Float]] = [], background: [[Float]] = []
                for sample in samples {
                    let image = PlaneProcessor.planeImage(of: sample, plane: plane, rect: context, component: component)
                    var pixels = [Float](repeating: 0, count: local.width * local.height)
                    for row in 0..<local.height {
                        for column in 0..<local.width {
                            pixels[row * local.width + column] = image[local.x + column, local.y + row]
                        }
                    }
                    observed.append(pixels)
                    background.append(SpatialFill.fill(image, rect: local))
                }
                return BlendEstimator.estimate(observed: observed, background: background)
            }

            let luma = estimate(plane: 0, component: 0)
            let strategy = WatermarkPlanner.strategy(for: luma.analysis)
            guard strategy == .unblend else {
                return RegionPlan(rect: rect, strategy: .spatial, maps: nil, analysis: luma.analysis)
            }

            // Chroma is un-mixed where it could be measured; where it could
            // not, the colour of the surroundings is used. A chroma sample
            // covers four luma pixels, so a sample is only trusted when all
            // of them were un-mixed.
            let cb = estimate(plane: 1, component: 0), cr = estimate(plane: 1, component: 1)
            let chromaWidth = rect.width / 2, chromaHeight = rect.height / 2
            func chromaMaps(_ result: BlendEstimator.Result) -> (slope: [Float], intercept: [Float]) {
                var slope = result.slope, intercept = result.intercept
                for row in 0..<chromaHeight {
                    for column in 0..<chromaWidth {
                        let index = row * chromaWidth + column
                        let lumaSlopes = [
                            luma.slope[(row * 2) * rect.width + column * 2], luma.slope[(row * 2) * rect.width + column * 2 + 1],
                            luma.slope[(row * 2 + 1) * rect.width + column * 2], luma.slope[(row * 2 + 1) * rect.width + column * 2 + 1]
                        ]
                        if lumaSlopes.allSatisfy({ $0 == 1 }) {
                            // No mark here in luma: leave chroma alone too.
                            slope[index] = 1
                            intercept[index] = 0
                        } else if lumaSlopes.contains(where: { $0 < BlendEstimator.minimumSlope }) {
                            slope[index] = 0
                        }
                    }
                }
                return (slope, intercept)
            }
            let cbMaps = chromaMaps(cb), crMaps = chromaMaps(cr)

            let maps = [
                PlaneProcessor.BlendMaps(
                    slope: try processor.makeMapTexture(width: rect.width, height: rect.height, components: [luma.slope]),
                    intercept: try processor.makeMapTexture(width: rect.width, height: rect.height, components: [luma.intercept])
                ),
                PlaneProcessor.BlendMaps(
                    slope: try processor.makeMapTexture(width: chromaWidth, height: chromaHeight, components: [cbMaps.slope, crMaps.slope]),
                    intercept: try processor.makeMapTexture(width: chromaWidth, height: chromaHeight, components: [cbMaps.intercept, crMaps.intercept])
                )
            ]
            return RegionPlan(rect: rect, strategy: .unblend, maps: maps, analysis: luma.analysis)
        }
    }
}
