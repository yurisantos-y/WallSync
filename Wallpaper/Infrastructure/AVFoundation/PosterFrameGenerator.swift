import AppKit
import AVFoundation
import Foundation

actor PosterFrameGenerator {
    func generatePoster(for url: URL, maxPixelSize: CGSize) throws -> NSImage {
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

    private static func image(from image: CGImage, constrainedTo maximumSize: CGSize) -> NSImage {
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
            return nsImage(from: image)
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))

        guard let resizedImage = context.makeImage() else {
            return nsImage(from: image)
        }

        return nsImage(from: resizedImage)
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
