import AppKit
import Foundation

@MainActor
final class DisplayManager: DisplayProviding {
    func currentDisplays() -> [DisplayTarget] {
        let separateSpaces = NSScreen.screensHaveSeparateSpaces

        return NSScreen.screens.compactMap { screen in
            guard let displayID = screen.cgDirectDisplayID else {
                return nil
            }

            return DisplayTarget(
                displayUUID: DisplayIdentity.uuidString(for: displayID),
                cgDisplayID: displayID,
                localizedName: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                isPrimary: screen == NSScreen.screens.first,
                maximumFramesPerSecond: screen.maximumFramesPerSecond,
                hasSeparateSpaceContext: separateSpaces
            )
        }
    }
}
