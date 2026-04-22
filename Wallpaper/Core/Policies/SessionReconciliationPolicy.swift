import Foundation

struct DesiredWallpaperSession: Hashable, Sendable {
    var display: DisplayTarget
    var asset: WallpaperAsset
    var placement: WallpaperPlacement
}

struct SessionReconciliationPolicy {
    func desiredSessions(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement]
    ) -> [DesiredWallpaperSession] {
        let placementIndex = PlacementIndex(placements: placements.filter(\.isEnabled))
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        return displays.compactMap { display in
            guard let placement = placementIndex.resolvedPlacement(for: display),
                  let asset = assetsByID[placement.assetID] else {
                return nil
            }

            return DesiredWallpaperSession(display: display, asset: asset, placement: placement)
        }
    }

    func resolvedPlacement(
        for display: DisplayTarget,
        placements: [WallpaperPlacement]
    ) -> WallpaperPlacement? {
        PlacementIndex(placements: placements.filter(\.isEnabled)).resolvedPlacement(for: display)
    }
}

private struct PlacementIndex {
    private let exactPlacements: [String: WallpaperPlacement]
    private let primaryPlacement: WallpaperPlacement?
    private let globalPlacement: WallpaperPlacement?

    init(placements: [WallpaperPlacement]) {
        var exactPlacements: [String: WallpaperPlacement] = [:]
        var primaryPlacement: WallpaperPlacement?
        var globalPlacement: WallpaperPlacement?

        for placement in placements {
            switch placement.scope {
            case let .specificDisplay(displayUUID):
                if exactPlacements[displayUUID] == nil {
                    exactPlacements[displayUUID] = placement
                }
            case .primaryOnly:
                if primaryPlacement == nil {
                    primaryPlacement = placement
                }
            case .allDisplays:
                if globalPlacement == nil {
                    globalPlacement = placement
                }
            }
        }

        self.exactPlacements = exactPlacements
        self.primaryPlacement = primaryPlacement
        self.globalPlacement = globalPlacement
    }

    func resolvedPlacement(for display: DisplayTarget) -> WallpaperPlacement? {
        if let exactPlacement = exactPlacements[display.displayUUID] {
            return exactPlacement
        }

        if display.isPrimary, let primaryPlacement {
            return primaryPlacement
        }

        return globalPlacement
    }
}
