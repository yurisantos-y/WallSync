import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct StoredPoster: Sendable, Equatable {
    var posterPath: String
    var thumbnailPath: String?
}

actor PosterCacheStore {
    static let thumbnailMaximumDimension: CGFloat = 480

    private let storage: StorageLocations
    private let memoryCache = NSCache<NSString, CGImageBox>()

    init(storage: StorageLocations) {
        self.storage = storage
        memoryCache.countLimit = 32
        memoryCache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Writes the full-size poster and a small library thumbnail, both HEIC
    /// (a fraction of the size of PNG for photographic frames), straight from
    /// the `CGImage` — no TIFF round trip. Posters written as PNG by earlier
    /// versions keep loading through `loadPoster`.
    func savePoster(_ box: CGImageBox, for assetID: UUID) throws -> StoredPoster {
        let image = box.image
        let directory = StorageLocations.postersDirectoryName
        let posterPath = "\(directory)/\(assetID.uuidString).heic"
        try Self.write(image, to: storage.url(forRelativePath: posterPath), type: .heic, quality: 0.9)
        memoryCache.setObject(box, forKey: posterPath as NSString, cost: image.memoryCost)

        var thumbnailPath: String?
        if let thumbnail = Self.downscaled(image, maximumDimension: Self.thumbnailMaximumDimension) {
            let path = "\(directory)/\(assetID.uuidString)-thumb.heic"
            if (try? Self.write(thumbnail, to: storage.url(forRelativePath: path), type: .heic, quality: 0.8)) != nil {
                thumbnailPath = path
            }
        }

        return StoredPoster(posterPath: posterPath, thumbnailPath: thumbnailPath)
    }

    func loadPoster(relativePath: String?) -> CGImageBox? {
        guard let relativePath else { return nil }
        let cacheKey = relativePath as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let url = storage.url(forRelativePath: relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }

        let box = CGImageBox(image)
        memoryCache.setObject(box, forKey: cacheKey, cost: image.memoryCost)
        return box
    }

    func evict(relativePath: String?) {
        guard let relativePath else { return }
        memoryCache.removeObject(forKey: relativePath as NSString)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw PosterCacheError.encodingFailed
        }

        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PosterCacheError.encodingFailed
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }

    /// Returns a copy no larger than `maximumDimension` on its longest side.
    static func downscaled(_ image: CGImage, maximumDimension: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > 0 else { return nil }
        let scale = min(1, maximumDimension / longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

extension CGImage {
    var memoryCost: Int {
        max(1, bytesPerRow * height)
    }
}

enum PosterCacheError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "The video poster could not be encoded.")
        }
    }
}
