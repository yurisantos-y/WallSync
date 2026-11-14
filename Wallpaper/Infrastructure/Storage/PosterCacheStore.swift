import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor PosterCacheStore {
    private let storage: StorageLocations
    private let memoryCache = NSCache<NSString, CGImageBox>()

    init(storage: StorageLocations) {
        self.storage = storage
        memoryCache.countLimit = 32
        memoryCache.totalCostLimit = 96 * 1024 * 1024
    }

    func savePoster(_ box: CGImageBox, for assetID: UUID) throws -> String {
        let image = box.image
        let relativePath = "\(StorageLocations.postersDirectoryName)/\(assetID.uuidString).png"
        try Self.write(image, to: storage.url(forRelativePath: relativePath), type: .png)
        memoryCache.setObject(CGImageBox(image), forKey: relativePath as NSString, cost: image.memoryCost)
        return relativePath
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
