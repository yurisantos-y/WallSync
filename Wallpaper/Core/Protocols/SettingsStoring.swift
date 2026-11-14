import Foundation

protocol SettingsStoring: Actor {
    func loadPreferences() -> StoreLoadResult<UserPreferences>
    func savePreferences(_ preferences: UserPreferences) throws
    func loadPlacements() -> StoreLoadResult<[WallpaperPlacement]>
    func savePlacements(_ placements: [WallpaperPlacement]) throws
}
