import CoreGraphics
import Foundation

struct DisplayOcclusionDetector {
    private enum Constant {
        static let coverageThreshold: CGFloat = 0.95
        static let minimumWindowWidth: CGFloat = 64
        static let minimumWindowHeight: CGFloat = 64
    }

    func isDisplayCovered(_ display: DisplayTarget, windows: [[String: Any]]? = nil) -> Bool {
        coverageRatio(for: display, windows: windows) >= Constant.coverageThreshold
    }

    func isDisplayCovered(_ display: DisplayTarget, snapshot: WindowListSnapshot) -> Bool {
        coverageRatio(for: display, snapshot: snapshot) >= Constant.coverageThreshold
    }

    func coverageRatio(for display: DisplayTarget, windows: [[String: Any]]? = nil) -> CGFloat {
        let snapshot = windows.map(WindowListSnapshot.init(rawWindows:)) ?? WindowListProvider.captureOnScreenWindows()
        return coverageRatio(for: display, snapshot: snapshot)
    }

    func coverageRatio(for display: DisplayTarget, snapshot: WindowListSnapshot) -> CGFloat {
        let displayArea = display.frame.width * display.frame.height
        guard displayArea > 0 else { return 0 }

        let coveredRectangles = snapshot.windows.compactMap { window -> CGRect? in
            guard window.layer == 0,
                  window.alpha > 0,
                  window.bounds.width >= Constant.minimumWindowWidth,
                  window.bounds.height >= Constant.minimumWindowHeight else {
                return nil
            }
            let overlap = window.bounds.intersection(display.frame)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return overlap
        }

        return Self.unionArea(of: coveredRectangles) / displayArea
    }

    static func unionArea(of rectangles: [CGRect]) -> CGFloat {
        let rectangles = rectangles.filter { !$0.isNull && !$0.isEmpty }
        guard !rectangles.isEmpty else { return 0 }

        let xCoordinates = Set(rectangles.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xCoordinates.count > 1 else { return 0 }

        var area: CGFloat = 0

        for index in 0..<(xCoordinates.count - 1) {
            let left = xCoordinates[index]
            let right = xCoordinates[index + 1]
            let width = right - left
            guard width > 0 else { continue }

            var yIntervals: [(CGFloat, CGFloat)] = []
            for rectangle in rectangles where rectangle.minX < right && rectangle.maxX > left {
                yIntervals.append((rectangle.minY, rectangle.maxY))
            }
            yIntervals.sort { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }

            area += width * mergedLength(of: yIntervals)
        }

        return area
    }

    private static func mergedLength(of intervals: [(CGFloat, CGFloat)]) -> CGFloat {
        guard var current = intervals.first else { return 0 }
        var total: CGFloat = 0

        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }

        total += current.1 - current.0
        return total
    }
}
