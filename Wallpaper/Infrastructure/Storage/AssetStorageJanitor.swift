import Foundation

/// Deletes media files owned by removed assets and sweeps files that no asset
/// references (left behind by older versions or interrupted imports).
actor AssetStorageJanitor {
    private let storage: StorageLocations
    private let fileManager = FileManager.default

    init(storage: StorageLocations) {
        self.storage = storage
    }

    func removeFiles(ownedBy asset: WallpaperAsset) {
        for relativePath in OrphanCleanupPolicy.relativePaths(ownedBy: asset) {
            try? fileManager.removeItem(at: storage.url(forRelativePath: relativePath))
        }
    }

    func removeFile(relativePath: String) {
        try? fileManager.removeItem(at: storage.url(forRelativePath: relativePath))
    }

    /// Returns the number of bytes reclaimed.
    @discardableResult
    func removeOrphans(keeping assets: [WallpaperAsset]) -> Int64 {
        let referenced = OrphanCleanupPolicy.referencedRelativePaths(for: assets)
        var existing: [String] = []

        for directoryName in [StorageLocations.optimizedDirectoryName, StorageLocations.postersDirectoryName] {
            let directory = storage.root.appendingPathComponent(directoryName, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            existing.append(contentsOf: names.map { "\(directoryName)/\($0)" })
        }

        var reclaimed: Int64 = 0
        for relativePath in OrphanCleanupPolicy.orphans(existingRelativePaths: existing, referenced: referenced) {
            let url = storage.url(forRelativePath: relativePath)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fileManager.removeItem(at: url)) != nil {
                reclaimed += Int64(size)
            }
        }
        return reclaimed
    }
}
