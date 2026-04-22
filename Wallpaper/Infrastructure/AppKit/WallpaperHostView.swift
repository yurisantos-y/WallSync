import AppKit
import AVFoundation
import Foundation

final class WallpaperHostView: NSView {
    private let posterLayer = CALayer()
    private let videoLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        configure(layer: posterLayer)
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.isHidden = false
        configure(layer: videoLayer)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.isHidden = true

        layer?.addSublayer(posterLayer)
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimations {
            posterLayer.frame = bounds
            videoLayer.frame = bounds
        }
    }

    func attach(player: AVPlayer?, poster: NSImage?, contentMode: WallpaperPlacement.ContentMode) {
        videoLayer.player = player
        updatePoster(poster)
        setContentMode(contentMode)
    }

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        let gravity: CALayerContentsGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
        posterLayer.contentsGravity = gravity
        videoLayer.videoGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
    }

    func updatePoster(_ image: NSImage?) {
        withoutImplicitAnimations {
            posterLayer.contents = image
        }
    }

    func showVideoLayer() {
        withoutImplicitAnimations {
            posterLayer.isHidden = true
            videoLayer.isHidden = false
        }
    }

    func showPosterLayer() {
        withoutImplicitAnimations {
            videoLayer.isHidden = true
            posterLayer.isHidden = false
        }
    }

    func detachPlayer() {
        videoLayer.player = nil
        showPosterLayer()
    }

    private func configure(layer: CALayer) {
        layer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
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
