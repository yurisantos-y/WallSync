import AppKit
import Foundation

@MainActor
final class DesktopWallpaperWindowController: NSWindowController, WallpaperSurface, VideoFrameHosting {
    private(set) var displayTarget: DisplayTarget
    let hostView: WallpaperHostView
    var onOcclusionChange: (() -> Void)?

    private let occlusionObserver = OcclusionObserver()
    private var isWindowVisible = false

    init(displayTarget: DisplayTarget) {
        self.displayTarget = displayTarget
        self.hostView = WallpaperHostView(frame: CGRect(origin: .zero, size: displayTarget.frame.size))
        let window = DesktopWallpaperWindow(frame: displayTarget.frame)
        super.init(window: window)

        window.contentView = hostView
        window.setFrame(displayTarget.frame, display: true)

        occlusionObserver.startObserving(window: window) { [weak self] _ in
            self?.onOcclusionChange?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isOccluded: Bool {
        // A window we ordered out ourselves says nothing about what covers
        // the desktop; only the display coverage counts then.
        guard let window else { return true }
        return isWindowVisible && !window.occlusionState.contains(.visible)
    }

    func update(displayTarget target: DisplayTarget) {
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

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        hostView.setContentMode(contentMode)
    }

    func setPoster(_ image: CGImage?) {
        hostView.setPoster(image)
    }

    func setContentCrop(_ crop: CGRect?) {
        hostView.setContentCrop(crop)
    }

    func setDimming(_ overlay: DimOverlay?) {
        hostView.setDimming(overlay)
    }

    func showPoster() {
        hostView.setVideoVisible(false)
    }

    func showVideo() {
        hostView.setVideoVisible(true)
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

    override func close() {
        occlusionObserver.invalidate()
        onOcclusionChange = nil
        hostView.setPlayer(nil)
        hide()
        super.close()
    }
}
