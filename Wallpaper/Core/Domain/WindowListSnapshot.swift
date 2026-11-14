import CoreGraphics
import Foundation

/// The attributes of an on-screen window that the occlusion and fullscreen
/// detectors care about.
struct WindowInfo: Sendable, Equatable {
    var ownerPID: Int32
    var layer: Int
    var alpha: Double
    var bounds: CGRect
}

/// One capture of the on-screen window list. It is taken once per reconcile
/// and shared by every detector and every session, instead of each of them
/// querying the window server on its own.
struct WindowListSnapshot: Sendable, Equatable {
    var windows: [WindowInfo]

    init(windows: [WindowInfo]) {
        self.windows = windows
    }

    /// Parses the dictionaries returned by `CGWindowListCopyWindowInfo`.
    init(rawWindows: [[String: Any]]) {
        windows = rawWindows.compactMap(Self.parse)
    }

    private static func parse(_ window: [String: Any]) -> WindowInfo? {
        guard let ownerPID = number(in: window, key: "kCGWindowOwnerPID"),
              let layer = number(in: window, key: "kCGWindowLayer"),
              let alpha = number(in: window, key: "kCGWindowAlpha"),
              let boundsDictionary = window["kCGWindowBounds"] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }

        return WindowInfo(
            ownerPID: ownerPID.int32Value,
            layer: layer.intValue,
            alpha: alpha.doubleValue,
            bounds: bounds
        )
    }

    private static func number(in window: [String: Any], key: String) -> NSNumber? {
        if let number = window[key] as? NSNumber { return number }
        if let intValue = window[key] as? Int { return NSNumber(value: intValue) }
        if let doubleValue = window[key] as? Double { return NSNumber(value: doubleValue) }
        return nil
    }
}
