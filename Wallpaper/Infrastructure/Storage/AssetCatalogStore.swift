import Foundation

actor AssetCatalogStore {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let supportDirectory = try! fileManager.wallpaperApplicationSupportDirectory()
        self.fileURL = supportDirectory.appendingPathComponent("assets.json")
    }

    func loadAssets() throws -> [WallpaperAsset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([WallpaperAsset].self, from: data)
    }

    func saveAssets(_ assets: [WallpaperAsset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(assets)
        try data.write(to: fileURL, options: .atomic)
    }
}
