import Foundation

enum AssetInspector {
    static func technicalSummary(for asset: WallpaperAsset) -> String {
        let bitrateMbps = asset.estimatedBitRate / 1_000_000
        return "\(asset.containerType.uppercased()) • \(asset.codecType) • \(asset.resolutionDescription) • \(Int(asset.frameRate.rounded())) fps • \(String(format: "%.1f", bitrateMbps)) Mbps"
    }

    static func statusText(for asset: WallpaperAsset) -> String {
        switch asset.eligibility.tier {
        case .safe:
            return "Pronto para animar"
        case .warning:
            return "Uso com cautela"
        case .unsupported:
            return "Nao suportado no MVP"
        }
    }
}
