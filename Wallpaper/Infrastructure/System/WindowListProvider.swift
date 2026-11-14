import ApplicationServices
import Foundation

enum WindowListProvider {
    /// Queries the window server for the on-screen windows. This is the only
    /// place in the app that calls `CGWindowListCopyWindowInfo`.
    static func captureOnScreenWindows() -> WindowListSnapshot {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return WindowListSnapshot(rawWindows: raw)
    }
}
