import AppKit
import Foundation

actor PosterCacheStore {
    private let postersDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()

    init(fileManager: FileManager = .default) {
        let supportDirectory = try! fileManager.wallpaperApplicationSupportDirectory()
        self.postersDirectory = supportDirectory.appendingPathComponent("Posters", isDirectory: true)
        memoryCache.countLimit = 32
        memoryCache.totalCostLimit = 96 * 1024 * 1024

        if !fileManager.fileExists(atPath: postersDirectory.path) {
            try? fileManager.createDirectory(at: postersDirectory, withIntermediateDirectories: true)
        }
    }

    func savePoster(_ image: NSImage, for assetID: UUID) throws -> String {
        let relativePath = "Posters/\(assetID.uuidString).png"
        let destination = postersDirectory.appendingPathComponent("\(assetID.uuidString).png")
        guard let data = image.pngData() else {
            throw PosterCacheError.encodingFailed
        }
        try data.write(to: destination, options: .atomic)
        memoryCache.setObject(image, forKey: relativePath as NSString, cost: image.memoryCost)
        return relativePath
    }

    func loadPoster(relativePath: String?) -> NSImage? {
        guard let relativePath else { return nil }
        let cacheKey = relativePath as NSString
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let supportDirectory = try? FileManager.default.wallpaperApplicationSupportDirectory()
        guard let supportDirectory else { return nil }
        let image = NSImage(contentsOf: supportDirectory.appendingPathComponent(relativePath))
        if let image {
            memoryCache.setObject(image, forKey: cacheKey, cost: image.memoryCost)
        }
        return image
    }
}

private extension NSImage {
    var memoryCost: Int {
        guard let representation = representations.first else {
            let width = max(1, Int(size.width))
            let height = max(1, Int(size.height))
            return width * height * 4
        }

        let width = max(1, representation.pixelsWide)
        let height = max(1, representation.pixelsHigh)
        return width * height * 4
    }
}

enum PosterCacheError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Nao foi possivel codificar o poster do video."
        }
    }
}
