import Foundation

/// The short list of wallpapers offered in the menu bar.
enum RecentWallpapers {
    struct Item: Equatable, Sendable {
        var assetID: UUID
        var name: String
        /// On at least one display right now.
        var isActive: Bool
    }

    static let defaultLimit = 6

    /// Most recently used first; wallpapers never used follow, newest import
    /// first. Videos that cannot be played are left out.
    static func items(
        assets: [WallpaperAsset],
        activeAssetIDs: Set<UUID>,
        limit: Int = defaultLimit
    ) -> [Item] {
        let evaluator = PlaybackEligibilityEvaluator()
        return assets
            .filter { evaluator.effectiveProfile(for: $0).tier != .unsupported }
            .sorted { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return lhs.importedAt == rhs.importedAt
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : lhs.importedAt > rhs.importedAt
                }
            }
            .prefix(max(0, limit))
            .map { Item(assetID: $0.id, name: $0.displayName, isActive: activeAssetIDs.contains($0.id)) }
    }
}
