import Foundation

struct RGBColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// Global dimming of every wallpaper, so icons and widgets stay readable.
struct DimmingSettings: Codable, Hashable, Sendable {
    /// 0 … `maximum`: how much of the wallpaper is replaced by the tint.
    var amount: Double = 0
    /// `nil` dims towards black.
    var tint: RGBColor? = nil
    /// Adds `darkAppearanceExtra` while the system uses the dark appearance.
    var dimMoreInDarkMode: Bool = false

    static let off = DimmingSettings()
    static let maximum = 0.8
    static let darkAppearanceExtra = 0.2
}

extension DimmingSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            amount: try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0,
            tint: try container.decodeIfPresent(RGBColor.self, forKey: .tint),
            dimMoreInDarkMode: try container.decodeIfPresent(Bool.self, forKey: .dimMoreInDarkMode) ?? false
        )
    }
}

/// A solid colour laid over the wallpaper with the given opacity.
struct DimOverlay: Hashable, Sendable {
    var opacity: Double
    var color: RGBColor
}

enum DimmingPolicy {
    /// The overlay for one wallpaper, or `nil` when nothing is dimmed — in
    /// which case no layer is added and nothing changes in the render path.
    static func overlay(
        for asset: WallpaperAsset,
        settings: DimmingSettings,
        isDarkAppearance: Bool
    ) -> DimOverlay? {
        var amount = asset.dimmingOverride ?? settings.amount
        guard amount.isFinite else { return nil }
        if settings.dimMoreInDarkMode && isDarkAppearance {
            amount += DimmingSettings.darkAppearanceExtra
        }
        amount = min(max(amount, 0), DimmingSettings.maximum)
        guard amount > 0.001 else { return nil }
        return DimOverlay(opacity: amount, color: settings.tint ?? .black)
    }
}
