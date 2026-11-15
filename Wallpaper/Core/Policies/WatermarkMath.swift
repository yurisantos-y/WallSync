import Foundation

/// One plane of a picture as floating-point samples, row by row.
struct PlaneImage: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: fill, count: max(0, width * height)))
    }

    subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    func clamped(_ x: Int, _ y: Int) -> Float {
        pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }
}

/// A rectangle on the pixel grid.
struct PixelRect: Sendable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    func insetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    func clipped(width imageWidth: Int, height imageHeight: Int) -> PixelRect {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(maxX, imageWidth), y1 = min(maxY, imageHeight)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

/// Fills a rectangle from the pixels just outside it.
///
/// Every pixel inside is a weighted average of samples taken along the
/// rectangle's border, the weight falling with the cube of the distance, so
/// the fill meets the surroundings at the edges and is smooth inside. Being
/// an average of many border samples it carries almost none of their noise,
/// and it follows the surroundings smoothly from frame to frame: no flicker.
///
/// The GPU kernel that writes the final pixels (`removeMark` in
/// `PlaneShaders`) uses exactly the same samples and weights; this version
/// is what the analysis uses to predict the background behind a mark.
enum SpatialFill {
    /// Border samples are at most this many, however large the region.
    static let maximumSamples = 160
    /// Each sample averages this many pixels going outwards.
    static let sampleDepth = 3

    static func stride(for rect: PixelRect) -> Int {
        max(1, Int((Double(2 * (rect.width + rect.height)) / Double(maximumSamples)).rounded(.up)))
    }

    /// Positions of the border samples, and their values in `image`.
    static func samples(of image: PlaneImage, around rect: PixelRect) -> [(x: Float, y: Float, value: Float)] {
        let step = stride(for: rect)
        var result: [(x: Float, y: Float, value: Float)] = []

        func average(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Float {
            var total: Float = 0
            for depth in 0..<sampleDepth {
                total += image.clamped(x + dx * depth, y + dy * depth)
            }
            return total / Float(sampleDepth)
        }

        var position = rect.x
        while position < rect.maxX {
            let x = min(position + step / 2, rect.maxX - 1)
            if rect.y >= 1 { result.append((Float(x), Float(rect.y - 1), average(x, rect.y - 1, 0, -1))) }
            if rect.maxY < image.height { result.append((Float(x), Float(rect.maxY), average(x, rect.maxY, 0, 1))) }
            position += step
        }
        position = rect.y
        while position < rect.maxY {
            let y = min(position + step / 2, rect.maxY - 1)
            if rect.x >= 1 { result.append((Float(rect.x - 1), Float(y), average(rect.x - 1, y, -1, 0))) }
            if rect.maxX < image.width { result.append((Float(rect.maxX), Float(y), average(rect.maxX, y, 1, 0))) }
            position += step
        }
        return result
    }

    /// The fill for every pixel of `rect`, row by row.
    static func fill(_ image: PlaneImage, rect: PixelRect) -> [Float] {
        let samples = samples(of: image, around: rect)
        var output = [Float](repeating: 0, count: rect.width * rect.height)
        guard !samples.isEmpty else { return output }

        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let px = Float(rect.x + column), py = Float(rect.y + row)
                var total: Float = 0
                var weights: Float = 0
                for sample in samples {
                    let dx = sample.x - px, dy = sample.y - py
                    let squared = dx * dx + dy * dy + 0.25
                    let weight = 1 / (squared * squared.squareRoot())
                    total += weight * sample.value
                    weights += weight
                }
                output[row * rect.width + column] = total / weights
            }
        }
        return output
    }
}

/// Measures how a fixed translucent mark was mixed into the picture.
///
/// A translucent logo is added with a constant opacity `a` and colour `C`:
/// `observed = (1 - a) * background + a * C`. Across many frames, at one
/// pixel, `observed` is therefore a straight line in `background`, with
/// slope `1 - a` and intercept `a * C`. The background behind the mark is
/// not known, but it is predicted well from the surroundings (`SpatialFill`)
/// and only its variation over time matters, so a least-squares line through
/// the frames gives slope and intercept per pixel, and the original is
/// recovered as `(observed - intercept) / slope`. This also yields the real
/// outline of the mark: pixels that fit the identity line are not marked and
/// are left bit for bit as they are.
enum BlendEstimator {
    struct Result: Sendable {
        /// `1 - opacity` per pixel; 1 where the pixel is not marked, 0 where
        /// the mix could not be measured (opaque or unreliable).
        var slope: [Float]
        /// `opacity * colour` per pixel.
        var intercept: [Float]
        var analysis: WatermarkPlanner.RegionAnalysis
    }

    /// Below this slope the mark hides too much: dividing by it would
    /// amplify noise, so the pixel is filled instead.
    static let minimumSlope: Float = 0.15
    /// How far the frames may scatter around the fitted line. The predicted
    /// background misses fine texture, which shows up here as scatter.
    static let maximumResidual: Float = 0.06

    /// - Parameters:
    ///   - observed: for each sampled frame, the pixels of the region.
    ///   - background: for each sampled frame, the predicted background.
    static func estimate(observed: [[Float]], background: [[Float]]) -> Result {
        let count = observed.first?.count ?? 0
        let frames = Float(observed.count)
        var slope = [Float](repeating: 1, count: count)
        var intercept = [Float](repeating: 0, count: count)
        var marked = 0
        var translucent = 0
        guard observed.count >= 4, observed.count == background.count else {
            return Result(slope: slope, intercept: intercept, analysis: .init(translucentFraction: 0, markedFraction: 0))
        }

        for index in 0..<count {
            var meanObserved: Float = 0
            var meanBackground: Float = 0
            for frame in observed.indices {
                meanObserved += observed[frame][index]
                meanBackground += background[frame][index]
            }
            meanObserved /= frames
            meanBackground /= frames

            var covariance: Float = 0
            var variance: Float = 0
            var plainError: Float = 0
            for frame in observed.indices {
                let deltaBackground = background[frame][index] - meanBackground
                covariance += deltaBackground * (observed[frame][index] - meanObserved)
                variance += deltaBackground * deltaBackground
                plainError += abs(observed[frame][index] - background[frame][index])
            }
            variance /= frames
            covariance /= frames
            plainError /= frames

            // Looks like its surroundings in every frame: not marked.
            if plainError < 0.012 {
                continue
            }

            // The background must vary for the line to be measurable.
            guard variance > 2e-4 else {
                // A constant offset from the prediction, on a background
                // that never changes: marked, but not measurable.
                if abs(meanObserved - meanBackground) >= 0.02 {
                    marked += 1
                    slope[index] = 0
                }
                continue
            }
            let fittedSlope = covariance / variance
            let fittedIntercept = meanObserved - fittedSlope * meanBackground

            // The prediction is only approximate, frame by frame, but its
            // errors average out: a pixel that on average equals its
            // predicted background and follows it one to one is unmarked.
            if abs(meanObserved - meanBackground) < 0.02, abs(fittedSlope - 1) < 0.2 {
                continue
            }
            marked += 1

            var residual: Float = 0
            for frame in observed.indices {
                residual += abs(observed[frame][index] - (fittedSlope * background[frame][index] + fittedIntercept))
            }
            residual /= frames

            if fittedSlope >= minimumSlope, fittedSlope <= 1.1, residual < maximumResidual {
                slope[index] = min(fittedSlope, 1)
                intercept[index] = fittedIntercept
                translucent += 1
            } else {
                slope[index] = 0
            }
        }

        return Result(
            slope: slope,
            intercept: intercept,
            analysis: .init(
                translucentFraction: marked > 0 ? Double(translucent) / Double(marked) : 0,
                markedFraction: count > 0 ? Double(marked) / Double(count) : 0
            )
        )
    }
}

/// Finds how far the picture moved between two frames.
enum MotionSearch {
    struct Shift: Equatable, Sendable {
        /// Content at `p` in the first image is at `p + (dx, dy)` in the second.
        var dx: Float
        var dy: Float
        /// Mean absolute difference at the best position, 0 … 1.
        var error: Float
    }

    /// Exhaustive search on small images, with a parabolic sub-pixel step.
    /// `exclude` (the mark, which does not move with the scene) is ignored.
    static func coarse(from a: PlaneImage, to b: PlaneImage, radius: Int, exclude: [PixelRect] = []) -> Shift {
        guard a.width == b.width, a.height == b.height, a.width > 2 * radius + 4, a.height > 2 * radius + 4 else {
            return Shift(dx: 0, dy: 0, error: 1)
        }

        func cost(_ dx: Int, _ dy: Int) -> Float {
            var total: Float = 0
            var count = 0
            var y = radius
            while y < a.height - radius {
                var x = radius
                while x < a.width - radius {
                    if !exclude.contains(where: { $0.contains(x, y) || $0.contains(x + dx, y + dy) }) {
                        total += abs(a[x, y] - b[x + dx, y + dy])
                        count += 1
                    }
                    x += 2
                }
                y += 2
            }
            return count > 0 ? total / Float(count) : 1
        }

        var best = (dx: 0, dy: 0, cost: Float.greatestFiniteMagnitude)
        for dy in -radius...radius {
            for dx in -radius...radius {
                let value = cost(dx, dy)
                // Prefer the smaller motion among equals (flat pictures).
                if value < best.cost - 1e-7 || (abs(value - best.cost) <= 1e-7 && dx * dx + dy * dy < best.dx * best.dx + best.dy * best.dy) {
                    best = (dx, dy, value)
                }
            }
        }

        func refine(_ lower: Float, _ centre: Float, _ upper: Float) -> Float {
            let denominator = lower - 2 * centre + upper
            guard denominator > 1e-9 else { return 0 }
            return min(max(0.5 * (lower - upper) / denominator, -0.5), 0.5)
        }
        var subX: Float = 0, subY: Float = 0
        if abs(best.dx) < radius { subX = refine(cost(best.dx - 1, best.dy), best.cost, cost(best.dx + 1, best.dy)) }
        if abs(best.dy) < radius { subY = refine(cost(best.dx, best.dy - 1), best.cost, cost(best.dx, best.dy + 1)) }
        return Shift(dx: Float(best.dx) + subX, dy: Float(best.dy) + subY, error: best.cost)
    }

    /// Refines a shift on full-resolution crops by matching the band of
    /// pixels around the mark. `current` and `candidate` are crops of two
    /// frames with the same origin; `rect` is the mark inside them. Only
    /// pixels whose counterpart lies outside the candidate's own mark are
    /// compared. Returns `nil` when no position can be evaluated.
    static func refine(
        current: PlaneImage, candidate: PlaneImage, rect: PixelRect,
        around initial: (dx: Int, dy: Int), radius: Int, band: Int = 6
    ) -> (dx: Int, dy: Int, error: Float)? {
        let outer = rect.insetBy(dx: -band, dy: -band).clipped(width: current.width, height: current.height)
        var ring: [(Int, Int)] = []
        var y = outer.y
        while y < outer.maxY {
            var x = outer.x
            while x < outer.maxX {
                if !rect.contains(x, y) { ring.append((x, y)) }
                x += 2
            }
            y += 2
        }
        guard ring.count >= 16 else { return nil }

        var best: (dx: Int, dy: Int, error: Float)?
        for dy in (initial.dy - radius)...(initial.dy + radius) {
            for dx in (initial.dx - radius)...(initial.dx + radius) {
                var total: Float = 0
                var count = 0
                for (x, y) in ring {
                    let cx = x + dx, cy = y + dy
                    guard cx >= 0, cy >= 0, cx < candidate.width, cy < candidate.height, !rect.contains(cx, cy) else { continue }
                    total += abs(current[x, y] - candidate[cx, cy])
                    count += 1
                }
                // Most of the band must be comparable for the match to count.
                guard count * 2 >= ring.count else { continue }
                let error = total / Float(count)
                if best == nil || error < best!.error {
                    best = (dx, dy, error)
                }
            }
        }
        return best
    }

    /// Whether a frame shifted by `(dx, dy)` shows, clear of its own mark,
    /// everything that is behind the mark in the current frame.
    static func uncovers(rect: PixelRect, dx: Int, dy: Int, margin: Int = 8) -> Bool {
        abs(dx) >= rect.width + margin || abs(dy) >= rect.height + margin
    }
}

/// Proposes where a fixed logo is, from frames sampled along the video.
///
/// A fixed mark is the set of pixels that hardly changes while the rest of
/// the video does. Edges are what gives a logo away, opaque or translucent:
/// the gradient at each pixel is taken in every frame and its median over
/// time is kept. Moving content averages out; edges that stay put remain.
enum WatermarkDetector {
    struct Proposal: Equatable, Sendable {
        /// Unit rectangles, origin top-left, largest first.
        var regions: [CGRect]
    }

    /// - Parameter frames: greyscale frames of equal size, spread over the
    ///   video. Returns no regions when the video is too still to tell a
    ///   logo from the scene.
    static func detect(frames: [PlaneImage]) -> Proposal {
        guard frames.count >= 6, let first = frames.first, first.width >= 16, first.height >= 16 else {
            return Proposal(regions: [])
        }
        let width = first.width, height = first.height
        let count = width * height

        // The scene has to change, otherwise everything is "static".
        var changing = 0
        var staticEdge = [Float](repeating: 0, count: count)
        var gradientsX = [Float](repeating: 0, count: frames.count)
        var gradientsY = [Float](repeating: 0, count: frames.count)
        var values = [Float](repeating: 0, count: frames.count)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                for (index, frame) in frames.enumerated() {
                    gradientsX[index] = (frame[x + 1, y] - frame[x - 1, y]) / 2
                    gradientsY[index] = (frame[x, y + 1] - frame[x, y - 1]) / 2
                    values[index] = frame[x, y]
                }
                let medianX = median(&gradientsX), medianY = median(&gradientsY)
                staticEdge[y * width + x] = (medianX * medianX + medianY * medianY).squareRoot()

                let low = values.min() ?? 0, high = values.max() ?? 0
                if high - low > 0.08 { changing += 1 }
            }
        }
        guard Double(changing) / Double(count) > 0.3 else { return Proposal(regions: []) }

        var sorted = staticEdge
        sorted.sort()
        let typical = sorted[count / 2]
        let threshold = max(0.035, typical * 6)

        var mask = [Bool](repeating: false, count: count)
        var marked = 0
        for index in 0..<count where staticEdge[index] > threshold {
            mask[index] = true
            marked += 1
        }
        // Static edges everywhere mean a static scene, not a logo.
        guard marked > 0, Double(marked) / Double(count) < 0.12 else { return Proposal(regions: []) }

        // Join the strokes of a logo into one blob.
        let joined = dilate(mask, width: width, height: height, radius: max(2, width / 60))
        let boxes = components(joined, width: width, height: height)
            .filter { box in
                let area = Double(box.width * box.height) / Double(count)
                return area >= 0.0004 && area <= 0.12 && box.width >= 3 && box.height >= 3
            }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(3)

        return Proposal(
            regions: boxes.map { box in
                CGRect(
                    x: CGFloat(box.x) / CGFloat(width), y: CGFloat(box.y) / CGFloat(height),
                    width: CGFloat(box.width) / CGFloat(width), height: CGFloat(box.height) / CGFloat(height)
                )
            }
        )
    }

    private static func median(_ values: inout [Float]) -> Float {
        values.sort()
        return values[values.count / 2]
    }

    private static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for dx in max(0, x - radius)...min(width - 1, x + radius) {
                    horizontal[y * width + dx] = true
                }
            }
        }
        var output = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where horizontal[y * width + x] {
                for dy in max(0, y - radius)...min(height - 1, y + radius) {
                    output[dy * width + x] = true
                }
            }
        }
        return output
    }

    private static func components(_ mask: [Bool], width: Int, height: Int) -> [PixelRect] {
        var visited = [Bool](repeating: false, count: mask.count)
        var boxes: [PixelRect] = []
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] && !visited[start] {
            var minX = width, minY = height, maxX = 0, maxY = 0
            stack.append(start)
            visited[start] = true
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let neighbour = ny * width + nx
                    if mask[neighbour] && !visited[neighbour] {
                        visited[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            boxes.append(PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        return boxes
    }
}
