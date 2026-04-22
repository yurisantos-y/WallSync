import ApplicationServices
import Foundation

struct FullscreenWindowDetector {
    private enum Constant {
        static let minimumWindowWidth: CGFloat = 320
        static let minimumWindowHeight: CGFloat = 240
        static let fullscreenThreshold: CGFloat = 0.97
    }

    func fullscreenDisplayUUIDs(
        displays: [DisplayTarget],
        excludingProcessID processID: pid_t = ProcessInfo.processInfo.processIdentifier,
        windows: [[String: Any]]? = nil
    ) -> Set<String> {
        let windows = windows ?? (
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        )

        var fullscreenDisplays: Set<String> = []

        for window in windows {
            guard let bounds = fullscreenCandidateBounds(for: window, excludingProcessID: processID) else {
                continue
            }

            for display in displays {
                let overlap = bounds.intersection(display.frame)
                guard !overlap.isNull else { continue }

                let displayArea = display.frame.width * display.frame.height
                guard displayArea > 0 else { continue }

                let overlapRatio = (overlap.width * overlap.height) / displayArea
                let windowRatio = (bounds.width * bounds.height) / displayArea

                if overlapRatio >= Constant.fullscreenThreshold,
                   windowRatio >= Constant.fullscreenThreshold {
                    fullscreenDisplays.insert(display.displayUUID)
                }
            }
        }

        return fullscreenDisplays
    }

    private func fullscreenCandidateBounds(
        for window: [String: Any],
        excludingProcessID processID: pid_t
    ) -> CGRect? {
        guard let ownerPID = number(in: window, key: kCGWindowOwnerPID as String).map({ pid_t($0.intValue) }),
              ownerPID != processID,
              let layer = number(in: window, key: kCGWindowLayer as String)?.intValue,
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
}
