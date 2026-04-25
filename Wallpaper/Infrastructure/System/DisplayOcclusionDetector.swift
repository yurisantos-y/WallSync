import ApplicationServices
import Foundation

struct DisplayOcclusionDetector {
    private enum Constant {
        static let coverageThreshold: CGFloat = 0.95
        static let minimumWindowWidth: CGFloat = 64
        static let minimumWindowHeight: CGFloat = 64
    }

    func isDisplayCovered(
        _ display: DisplayTarget,
        windows: [[String: Any]]? = nil
    ) -> Bool {
        coverageRatio(for: display, windows: windows) >= Constant.coverageThreshold
    }

    func coverageRatio(
        for display: DisplayTarget,
        windows: [[String: Any]]? = nil
    ) -> CGFloat {
        let windows = windows ?? (
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        )

        let displayArea = display.frame.width * display.frame.height
        guard displayArea > 0 else { return 0 }

        let coveredRectangles = windows.compactMap { window -> CGRect? in
            guard let bounds = normalWindowBounds(for: window) else { return nil }
            let overlap = bounds.intersection(display.frame)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return overlap
        }

        return Self.unionArea(of: coveredRectangles) / displayArea
    }

    private func normalWindowBounds(for window: [String: Any]) -> CGRect? {
        guard let layer = number(in: window, key: kCGWindowLayer as String)?.intValue,
              layer == 0,
              let alpha = number(in: window, key: kCGWindowAlpha as String)?.doubleValue,
              alpha > 0,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width >= Constant.minimumWindowWidth,
              bounds.height >= Constant.minimumWindowHeight else {
            return nil
        }

        return bounds
    }

    private func number(in window: [String: Any], key: String) -> NSNumber? {
        if let number = window[key] as? NSNumber {
            return number
        }

        if let intValue = window[key] as? Int {
            return NSNumber(value: intValue)
        }

        if let doubleValue = window[key] as? Double {
            return NSNumber(value: doubleValue)
        }

        return nil
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
