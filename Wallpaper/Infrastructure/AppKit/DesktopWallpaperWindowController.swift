import AppKit
import Foundation

@MainActor
final class DesktopWallpaperWindowController: NSWindowController {
    var displayTarget: DisplayTarget
    let hostView: WallpaperHostView
    var onOcclusionChange: ((Bool) -> Void)?

    private let occlusionObserver = OcclusionObserver()
    private let displayOcclusionDetector = DisplayOcclusionDetector()
    private var isWindowVisible = false

    init(displayTarget: DisplayTarget) {
        self.displayTarget = displayTarget
        self.hostView = WallpaperHostView(frame: CGRect(origin: .zero, size: displayTarget.frame.size))
        let window = DesktopWallpaperWindow(frame: displayTarget.frame)
        super.init(window: window)

        window.contentView = hostView
        window.setFrame(displayTarget.frame, display: true)
        show()

        occlusionObserver.startObserving(window: window) { [weak self] _ in
            guard let self else { return }
            self.onOcclusionChange?(self.isOccluded)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isOccluded: Bool {
        guard let window else { return true }
        return !window.occlusionState.contains(.visible) || displayOcclusionDetector.isDisplayCovered(displayTarget)
    }

    func updateDisplayTarget(_ target: DisplayTarget) {
        guard displayTarget != target else { return }
        displayTarget = target

        let targetHostFrame = CGRect(origin: .zero, size: target.frame.size)
        if hostView.frame != targetHostFrame {
            hostView.frame = targetHostFrame
        }

        if window?.frame != target.frame {
            window?.setFrame(target.frame, display: false, animate: false)
        }

        onOcclusionChange?(isOccluded)
    }

    func show() {
        guard !isWindowVisible else { return }
        isWindowVisible = true
        window?.orderFrontRegardless()
    }

    func hide() {
        guard isWindowVisible else { return }
        isWindowVisible = false
        window?.orderOut(nil)
    }

    func closeWindow() {
        occlusionObserver.invalidate()
        hide()
        close()
    }
}
