import Foundation

actor SettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let placementsURL: URL

    private enum DefaultsKeys {
        static let preferences = "wallpaper.preferences"
        static let corruptedPreferences = "wallpaper.preferences.corrupt"
    }

    init(defaults: UserDefaults = .standard, placementsURL: URL) {
        self.defaults = defaults
        self.placementsURL = placementsURL
    }

    func loadPreferences() -> StoreLoadResult<UserPreferences> {
        guard let data = defaults.data(forKey: DefaultsKeys.preferences) else {
            return StoreLoadResult(value: .defaultValue, issue: nil)
        }

        do {
            return StoreLoadResult(value: try JSONDecoder().decode(UserPreferences.self, from: data), issue: nil)
        } catch {
            defaults.set(data, forKey: DefaultsKeys.corruptedPreferences)
            defaults.removeObject(forKey: DefaultsKeys.preferences)
            return StoreLoadResult(
                value: .defaultValue,
                issue: .corruptedFile(name: DefaultsKeys.preferences, preservedAs: DefaultsKeys.corruptedPreferences)
            )
        }
    }

    func savePreferences(_ preferences: UserPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: DefaultsKeys.preferences)
    }

    func loadPlacements() -> StoreLoadResult<[WallpaperPlacement]> {
        JSONFile.load([WallpaperPlacement].self, from: placementsURL, defaultValue: [])
    }

    func savePlacements(_ placements: [WallpaperPlacement]) throws {
        try JSONFile.save(placements, to: placementsURL)
    }
}
