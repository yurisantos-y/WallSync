import Foundation

/// Decides which files in the app's media directories belong to no asset.
enum OrphanCleanupPolicy {
    /// Relative paths (from the storage root) that the catalog still uses.
    static func referencedRelativePaths(for assets: [WallpaperAsset]) -> Set<String> {
        var paths: Set<String> = []
        for asset in assets {
            paths.formUnion(relativePaths(ownedBy: asset))
        }
        return paths
    }

    /// Every file the given asset owns inside the storage root.
    static func relativePaths(ownedBy asset: WallpaperAsset) -> Set<String> {
        var paths: Set<String> = []
        if let optimized = asset.optimizedPlayback?.relativePath { paths.insert(optimized) }
        if let poster = asset.posterImageRelativePath { paths.insert(poster) }
        return paths
    }

    static func orphans(existingRelativePaths: [String], referenced: Set<String>) -> [String] {
        existingRelativePaths.filter { !referenced.contains($0) }.sorted()
    }
}
