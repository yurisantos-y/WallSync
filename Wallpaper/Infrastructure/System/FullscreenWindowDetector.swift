import CoreGraphics
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
        fullscreenDisplayUUIDs(
            displays: displays,
            excludingProcessID: processID,
            snapshot: windows.map(WindowListSnapshot.init(rawWindows:)) ?? WindowListProvider.captureOnScreenWindows()
        )
    }

    func fullscreenDisplayUUIDs(
        displays: [DisplayTarget],
        excludingProcessID processID: pid_t = ProcessInfo.processInfo.processIdentifier,
        snapshot: WindowListSnapshot
    ) -> Set<String> {
        var fullscreenDisplays: Set<String> = []

        for window in snapshot.windows {
            guard window.ownerPID != processID,
                  window.layer == 0,
                  window.alpha > 0,
                  window.bounds.width >= Constant.minimumWindowWidth,
                  window.bounds.height >= Constant.minimumWindowHeight else {
                continue
            }

            for display in displays {
                let overlap = window.bounds.intersection(display.frame)
                guard !overlap.isNull else { continue }

                let displayArea = display.frame.width * display.frame.height
                guard displayArea > 0 else { continue }

                let overlapRatio = (overlap.width * overlap.height) / displayArea
                let windowRatio = (window.bounds.width * window.bounds.height) / displayArea

                if overlapRatio >= Constant.fullscreenThreshold,
                   windowRatio >= Constant.fullscreenThreshold {
                    fullscreenDisplays.insert(display.displayUUID)
                }
            }
        }

        return fullscreenDisplays
    }
}
