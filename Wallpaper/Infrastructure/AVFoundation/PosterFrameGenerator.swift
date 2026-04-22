import AppKit
import AVFoundation
import Foundation

actor PosterFrameGenerator {
    func generatePoster(for url: URL) throws -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        return NSImage(cgImage: image, size: .zero)
    }
}
