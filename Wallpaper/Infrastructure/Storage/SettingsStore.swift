import Foundation

actor SettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let placementsURL: URL

    private enum DefaultsKeys {
        static let preferences = "wallpaper.preferences"
    }

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        let supportDirectory = try! fileManager.wallpaperApplicationSupportDirectory()
        self.placementsURL = supportDirectory.appendingPathComponent("placements.json")
    }

    func loadPreferences() throws -> UserPreferences {
        guard let data = defaults.data(forKey: DefaultsKeys.preferences) else {
            return .defaultValue
        }

        return try JSONDecoder().decode(UserPreferences.self, from: data)
    }

    func savePreferences(_ preferences: UserPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: DefaultsKeys.preferences)
    }

    func loadPlacements() throws -> [WallpaperPlacement] {
        guard FileManager.default.fileExists(atPath: placementsURL.path) else {
            return []
        }

        let data = try Data(contentsOf: placementsURL)
        return try JSONDecoder().decode([WallpaperPlacement].self, from: data)
    }

    func savePlacements(_ placements: [WallpaperPlacement]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(placements)
        try data.write(to: placementsURL, options: .atomic)
    }
}
