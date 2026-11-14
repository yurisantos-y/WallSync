import Foundation

actor AssetCatalogStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadAssets() -> StoreLoadResult<[WallpaperAsset]> {
        JSONFile.load([WallpaperAsset].self, from: fileURL, defaultValue: [])
    }

    func saveAssets(_ assets: [WallpaperAsset]) throws {
        try JSONFile.save(assets, to: fileURL)
    }
}
