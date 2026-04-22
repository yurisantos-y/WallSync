import Foundation

protocol SettingsStoring: Actor {
    func loadPreferences() throws -> UserPreferences
    func savePreferences(_ preferences: UserPreferences) throws
    func loadPlacements() throws -> [WallpaperPlacement]
    func savePlacements(_ placements: [WallpaperPlacement]) throws
}
