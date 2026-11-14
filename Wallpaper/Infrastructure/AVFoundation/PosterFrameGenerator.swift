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

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        return Self.image(from: image, constrainedTo: maxPixelSize)
    }

    private static func image(from image: CGImage, constrainedTo maximumSize: CGSize) -> CGImage {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let targetSize = constrainedSize(sourceSize: sourceSize, maximumSize: maximumSize)

        guard targetSize != sourceSize,
              let context = CGContext(
                data: nil,
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
