import CoreGraphics
import Foundation

/// Geometry of one video stretched across several displays.
///
/// The video fills the rectangle that encloses every display (aspect fill)
/// and each display shows the part of the picture that lies behind it, as if
/// the screens were windows onto the same image. This is geometry only: the
/// displays all receive the same decoded surface and each window shows a
/// different part of it, with no copy, no scaling on the CPU and no second
/// decoder.
///
/// Displays with different capabilities keep working because nothing here
/// depends on them. Each window's layer asks for extended dynamic range, so
/// the system tone-maps the same frame for an HDR display and for an SDR one
/// independently. Frames are produced at the video's frame rate and
/// committed in one transaction; a 120 Hz display simply repeats a frame
/// until the next one, exactly as it does for a single-display wallpaper.
enum PanoramaLayout {
    struct Display: Equatable, Sendable {
        var id: String
        /// Frame in global screen coordinates (points, origin bottom-left).
        var frame: CGRect
    }

    /// The rectangle enclosing every display.
    static func boundingRect(of displays: [Display]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// For each display, the part of the video it shows: a unit rectangle
    /// with the origin at the video's top-left corner.
    ///
    /// - Parameter offset: which part stays visible when the video is larger
    ///   than the bounding box, -1 … 1 per axis. `x = -1` keeps the left
    ///   edge, `y = -1` keeps the top edge, 0 is centred.
    static func crops(displays: [Display], videoSize: CGSize, offset: CGPoint = .zero) -> [String: CGRect] {
        let bounds = boundingRect(of: displays)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return [:]
        }

        let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let video = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let slack = CGSize(width: video.width - bounds.width, height: video.height - bounds.height)
        let shift = CGPoint(
            x: (min(max(offset.x, -1), 1) + 1) / 2,
            y: (min(max(offset.y, -1), 1) + 1) / 2
        )
        // The video's rectangle in global coordinates (y grows upwards).
        let videoMinX = bounds.minX - slack.width * shift.x
        let videoMaxY = bounds.maxY + slack.height * shift.y

        var result: [String: CGRect] = [:]
        for display in displays {
            result[display.id] = CGRect(
                x: (display.frame.minX - videoMinX) / video.width,
                y: (videoMaxY - display.frame.maxY) / video.height,
                width: display.frame.width / video.width,
                height: display.frame.height / video.height
            )
        }
        return result
    }

    /// Largest frame the hardware decoders are relied on for. VideoToolbox
    /// has no public query for this, so the values are conservative: 8K on
    /// Apple silicon, 4K on Intel.
    static var maximumDecodePixelSize: CGSize {
        #if arch(arm64)
        return CGSize(width: 8192, height: 4320)
        #else
        return CGSize(width: 4096, height: 2304)
        #endif
    }

    /// Pixel size a rendition needs so that every display of the span gets
    /// its native resolution: the bounding box at the highest scale factor,
    /// held within what the hardware decodes. The optimizer never enlarges a
    /// source beyond its own size, so a video without that many pixels is
    /// simply used as it is.
    static func targetPixelSize(displays: [DisplayTarget], limit: CGSize = maximumDecodePixelSize) -> CGSize {
        let bounds = boundingRect(of: displays.map { Display(id: $0.displayUUID, frame: $0.frame) })
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return displays.largestPixelSize
        }
        let scaleFactor = displays.map(\.backingScaleFactor).max() ?? 1
        let wanted = CGSize(width: bounds.width * scaleFactor, height: bounds.height * scaleFactor)
        let fit = min(1, limit.width / wanted.width, limit.height / wanted.height)
        return CGSize(width: (wanted.width * fit).rounded(.down), height: (wanted.height * fit).rounded(.down))
    }

    /// Whether the video is larger than the bounding box on each axis, i.e.
    /// whether the position offset has any effect there.
    static func hasSlack(displays: [Display], videoSize: CGSize) -> (horizontal: Bool, vertical: Bool) {
        let bounds = boundingRect(of: displays)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return (false, false)
        }
        let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
        return (videoSize.width * scale - bounds.width > 0.5, videoSize.height * scale - bounds.height > 0.5)
    }
}
