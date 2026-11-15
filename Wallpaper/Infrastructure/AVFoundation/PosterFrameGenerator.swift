import AppKit
import AVFoundation
import Foundation

actor PosterFrameGenerator {
    func generatePoster(for url: URL, maxPixelSize: CGSize) throws -> NSImage {
        Self.nsImage(from: try generatePosterImage(for: url, maxPixelSize: maxPixelSize))
    }

    func generatePosterBox(for url: URL, maxPixelSize: CGSize) throws -> CGImageBox {
        CGImageBox(try generatePosterImage(for: url, maxPixelSize: maxPixelSize))
    }

    func generatePosterImage(for url: URL, maxPixelSize: CGSize) throws -> CGImage {
        let signpost = Signpost.begin(Signpost.Name.posterGeneration)
        defer { Signpost.end(Signpost.Name.posterGeneration, signpost) }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxPixelSize
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        if #available(macOS 15.0, *) {
            // The poster is a standard-dynamic-range still (it also becomes
            // the system desktop picture). Ask for a tone-mapped frame so an
            // HDR video does not produce a washed-out or clipped poster.
            generator.dynamicRangePolicy = .forceSDR
        }

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        return Self.image(from: image, constrainedTo: maxPixelSize)
    }

    /// Always renders into sRGB: Core Graphics colour-matches from whatever
    /// space the decoded frame is in (Rec. 709, P3, BT.2020), so the stored
    /// poster has correct, display-independent colours.
    private static func image(from image: CGImage, constrainedTo maximumSize: CGSize) -> CGImage {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let targetSize = constrainedSize(sourceSize: sourceSize, maximumSize: maximumSize)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage() ?? image
    }

    private static func nsImage(from image: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: image)
        let size = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(representation)
        return nsImage
    }

    static func constrainedSize(sourceSize: CGSize, maximumSize: CGSize) -> CGSize {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              maximumSize.width > 0,
              maximumSize.height > 0 else {
            return sourceSize
        }

        let scale = min(1, maximumSize.width / sourceSize.width, maximumSize.height / sourceSize.height)
        return CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
    }
}
