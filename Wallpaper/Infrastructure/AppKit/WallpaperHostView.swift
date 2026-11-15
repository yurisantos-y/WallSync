import AppKit
import AVFoundation
import Foundation
import IOSurface

/// Layer tree of a wallpaper window, bottom to top:
///
/// 1. `posterLayer` — the still poster; always present, so there is never a
///    blank frame while a player starts.
/// 2. `frameLayer` — decoded frames pushed by a shared engine (one decode
///    presented on several displays), or the frozen last frame.
/// 3. `playerLayer` — direct `AVPlayerLayer` output, used when the video is
///    shown on a single display (the most efficient path).
final class WallpaperHostView: NSView {
    private let posterLayer = CALayer()
    private let videoContainer = CALayer()
    private let frameLayer = CALayer()
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.isOpaque = true
        layer = rootLayer

        for layer in [posterLayer, videoContainer, frameLayer, playerLayer] {
            configure(layer: layer)
        }
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.masksToBounds = true
        frameLayer.contentsGravity = .resizeAspectFill
        frameLayer.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        videoContainer.isHidden = true

        rootLayer.addSublayer(posterLayer)
        rootLayer.addSublayer(videoContainer)
        videoContainer.addSublayer(frameLayer)
        videoContainer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimations {
            posterLayer.frame = bounds
            videoContainer.frame = bounds
            frameLayer.frame = bounds
            playerLayer.frame = bounds
        }
    }

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        withoutImplicitAnimations {
            let gravity: CALayerContentsGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
            posterLayer.contentsGravity = gravity
            frameLayer.contentsGravity = gravity
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
            videoContainer.isHidden = !isVisible
        }
    }

    func setPlayer(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    /// Enables extended dynamic range output for HDR video.
    func setWantsExtendedDynamicRange(_ wantsEDR: Bool) {
        frameLayer.wantsExtendedDynamicRangeContent = wantsEDR
        playerLayer.wantsExtendedDynamicRangeContent = wantsEDR
    }

    /// Presents a decoded frame without copying it: the layer references the
    /// decoder's IOSurface directly. Callers batch this in a `CATransaction`.
    func presentFrame(_ surface: IOSurfaceRef) {
        frameLayer.contents = surface
    }

    /// Shows a still image in place of live frames (frozen frame).
    func setFrozenFrame(_ image: CGImage?) {
        withoutImplicitAnimations {
            frameLayer.contents = image
        }
    }

    /// The object currently shown by the frame layer; used by tests.
    var presentedFrameContents: Any? {
        frameLayer.contents
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

/// A surface whose video output is a `WallpaperHostView`.
@MainActor
protocol VideoFrameHosting: AnyObject {
    var hostView: WallpaperHostView { get }
}
