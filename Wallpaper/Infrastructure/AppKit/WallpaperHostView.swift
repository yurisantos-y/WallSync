import AppKit
import AVFoundation
import Foundation

/// Layer tree of a wallpaper window: a still poster at the bottom and the
/// video on top. The poster stays in place underneath the video so there is
/// never a blank frame while a player is starting.
final class WallpaperHostView: NSView {
    private let posterLayer = CALayer()
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.clear.cgColor
        layer = rootLayer

        configure(layer: posterLayer)
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        configure(layer: playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true

        rootLayer.addSublayer(posterLayer)
        rootLayer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimations {
            posterLayer.frame = bounds
            playerLayer.frame = bounds
        }
    }

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        withoutImplicitAnimations {
            posterLayer.contentsGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
            playerLayer.videoGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
        }
    }

    func setPoster(_ image: CGImage?) {
        withoutImplicitAnimations {
            posterLayer.contents = image
        }
    }

    func setVideoVisible(_ isVisible: Bool) {
        withoutImplicitAnimations {
            playerLayer.isHidden = !isVisible
        }
    }

    func setPlayer(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    private func configure(layer: CALayer) {
        layer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "contentsGravity": NSNull(),
            "hidden": NSNull(),
            "position": NSNull()
        ]
    }

    private func withoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
