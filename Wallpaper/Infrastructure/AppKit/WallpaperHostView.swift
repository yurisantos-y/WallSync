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
/// 4. `dimLayer` — only while dimming is configured: a solid colour with an
///    opacity. With dimming off the layer is not in the tree at all, so the
///    render path is exactly the one without the feature.
///
/// ## Why dimming is a layer and not baked into the video
///
/// Baking the dimming into the optimized rendition would cost nothing at
/// playback, but every adjustment of the slider would be a re-encode and the
/// automatic "dim more in dark mode" switch would be impossible. A solid
/// layer costs the app nothing per frame — it is composited by the window
/// server, which already blends the Dock, the menu bar, icons and widgets
/// over the wallpaper window — and works unchanged for HDR: the blend scales
/// the extended-range video instead of converting it to SDR.
///
/// The open question is whether one more blended layer moves the video off
/// a cheaper presentation path inside the window server. That can only be
/// answered with a power measurement on real hardware (scenario 9 in
/// `Distribution/PERFORMANCE.md`); it has not been measured yet.
final class WallpaperHostView: NSView {
    private let posterLayer = CALayer()
    private let videoContainer = CALayer()
    private let frameLayer = CALayer()
    let playerLayer = AVPlayerLayer()
    private var dimLayer: CALayer?
    private var transitionLayer: CALayer?
    private var contentCrop: CGRect?
    private var contentMode = WallpaperPlacement.ContentMode.aspectFill

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.isOpaque = true
        rootLayer.masksToBounds = true
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
            videoContainer.frame = bounds
            dimLayer?.frame = bounds
            applyContentGeometry()
        }
    }

    /// Shows only `crop` of the picture (unit rectangle, origin top-left),
    /// for a video that spans several displays; `nil` shows all of it.
    ///
    /// Pure geometry: the content layers are given the frame the whole
    /// picture would occupy and the view clips them to this display's part.
    /// The same decoded surface is used by every display; nothing is copied
    /// or scaled by the app.
    func setContentCrop(_ crop: CGRect?) {
        guard contentCrop != crop else { return }
        contentCrop = crop
        withoutImplicitAnimations {
            applyContentGeometry()
        }
    }

    private func applyContentGeometry() {
        let frame: CGRect
        if let crop = contentCrop, crop.width > 0, crop.height > 0 {
            let size = CGSize(width: bounds.width / crop.width, height: bounds.height / crop.height)
            frame = CGRect(
                x: -crop.minX * size.width,
                // Layer geometry grows upwards; the crop is measured from the top.
                y: bounds.height - size.height + crop.minY * size.height,
                width: size.width,
                height: size.height
            )
            // The frame already has the picture's proportions.
            posterLayer.contentsGravity = .resize
            frameLayer.contentsGravity = .resize
            playerLayer.videoGravity = .resize
        } else {
            frame = bounds
            let gravity: CALayerContentsGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
            posterLayer.contentsGravity = gravity
            frameLayer.contentsGravity = gravity
            playerLayer.videoGravity = contentMode == .aspectFit ? .resizeAspect : .resizeAspectFill
        }
        posterLayer.frame = frame
        frameLayer.frame = frame
        playerLayer.frame = frame
        transitionLayer?.frame = frame
        transitionLayer?.contentsGravity = posterLayer.contentsGravity
    }

    // MARK: - Wallpaper change

    /// Covers the new content with the picture that was on screen before a
    /// wallpaper change. The layer exists only for the length of the change.
    func setTransitionImage(_ image: CGImage?) {
        withoutImplicitAnimations {
            transitionLayer?.removeFromSuperlayer()
            transitionLayer = nil
            guard let image else { return }

            let layer = CALayer()
            configure(layer: layer)
            layer.actions?["opacity"] = NSNull()
            layer.contents = image
            layer.masksToBounds = true
            layer.frame = posterLayer.frame
            layer.contentsGravity = posterLayer.contentsGravity
            // Below the dimming layer, so old and new are dimmed alike.
            if let dimLayer {
                self.layer?.insertSublayer(layer, below: dimLayer)
            } else {
                self.layer?.addSublayer(layer)
            }
            transitionLayer = layer
        }
    }

    /// Dissolves the previous picture into the new wallpaper. The animation
    /// runs in the render server: the app does no work per frame.
    func fadeOutTransitionImage(duration: TimeInterval) {
        guard let layer = transitionLayer else { return }
        transitionLayer = nil

        guard duration > 0 else {
            withoutImplicitAnimations { layer.removeFromSuperlayer() }
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            layer.removeFromSuperlayer()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Whether the previous picture is still covering the content; used by tests.
    var hasTransitionImage: Bool { transitionLayer != nil }

    /// Frame of the content layers in view coordinates; used by tests.
    var contentLayerFrame: CGRect { frameLayer.frame }

    /// Adds, updates or removes the dimming layer.
    func setDimming(_ overlay: DimOverlay?) {
        withoutImplicitAnimations {
            guard let overlay else {
                dimLayer?.removeFromSuperlayer()
                dimLayer = nil
                return
            }

            let layer: CALayer
            if let dimLayer {
                layer = dimLayer
            } else {
                layer = CALayer()
                configure(layer: layer)
                layer.actions?["backgroundColor"] = NSNull()
                layer.actions?["opacity"] = NSNull()
                layer.frame = bounds
                self.layer?.addSublayer(layer)
                dimLayer = layer
            }
            layer.backgroundColor = CGColor(
                srgbRed: overlay.color.red, green: overlay.color.green, blue: overlay.color.blue, alpha: 1
            )
            layer.opacity = Float(overlay.opacity)
        }
    }

    /// Whether a dimming layer is in the tree; used by tests.
    var hasDimmingLayer: Bool { dimLayer?.superlayer != nil }

    /// Number of layers under the root; used by tests.
    var rootSublayerCount: Int { layer?.sublayers?.count ?? 0 }

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        self.contentMode = contentMode
        withoutImplicitAnimations {
            applyContentGeometry()
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
            "frame": NSNull(),
            "videoGravity": NSNull(),
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
