import AppKit
import Foundation

@MainActor
final class DesktopWallpaperWindowController: NSWindowController {
    var displayTarget: DisplayTarget
    let hostView: WallpaperHostView
    var onOcclusionChange: ((Bool) -> Void)?

    private let occlusionObserver = OcclusionObserver()
    private var isWindowVisible = false

    init(displayTarget: DisplayTarget) {
        self.displayTarget = displayTarget
        self.hostView = WallpaperHostView(frame: CGRect(origin: .zero, size: displayTarget.frame.size))
        let window = DesktopWallpaperWindow(frame: displayTarget.frame)
        super.init(window: window)

        window.contentView = hostView
        window.setFrame(displayTarget.frame, display: true)
        show()

        occlusionObserver.startObserving(window: window) { [weak self] isOccluded in
            self?.onOcclusionChange?(isOccluded)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isOccluded: Bool {
        guard let window else { return true }
        return !window.occlusionState.contains(.visible)
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
