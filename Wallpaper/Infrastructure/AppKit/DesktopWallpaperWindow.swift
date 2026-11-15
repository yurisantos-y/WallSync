import AppKit
import ApplicationServices
import Foundation

final class DesktopWallpaperWindow: NSWindow {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        // No `.fullScreenAuxiliary`: the wallpaper has no business inside
        // another app's fullscreen Space, and it is hidden there anyway.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Opaque with a solid background: the window server does not have to
        // composite the system wallpaper underneath on every video frame.
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = true
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
