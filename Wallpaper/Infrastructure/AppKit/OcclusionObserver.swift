import AppKit
import Foundation

@MainActor
final class OcclusionObserver {
    private var observer: NSObjectProtocol?

    func startObserving(window: NSWindow, handler: @escaping @MainActor (Bool) -> Void) {
        invalidate()

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                let isOccluded = !(window?.occlusionState.contains(.visible) ?? false)
                handler(isOccluded)
            }
        }
    }

    func invalidate() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
