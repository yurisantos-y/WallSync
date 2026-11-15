import AppKit
import ImageIO

/// Decodes library thumbnails off the main thread and keeps them in memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 200
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, maximumPixelDimension: Int = 480) async -> NSImage? {
        if let cached = cachedImage(for: url) {
            return cached
        }

        let decoded = await Task.detached(priority: .utility) {
            Self.decode(url: url, maximumPixelDimension: maximumPixelDimension)
        }.value

        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func evict(_ url: URL?) {
        guard let url else { return }
        cache.removeObject(forKey: url as NSURL)
    }

    /// Uses ImageIO's thumbnail path, which never materialises the full-size
    /// bitmap even when only the full poster exists on disk.
    private nonisolated static func decode(url: URL, maximumPixelDimension: Int) -> CGImageBox? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(CGImageBox.init)
    }
}
