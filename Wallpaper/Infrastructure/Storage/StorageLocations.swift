import Foundation

/// Every on-disk location the app writes to, resolved once at launch so that a
/// missing or unwritable Application Support directory surfaces as an error
/// instead of a crash.
struct StorageLocations: Sendable, Equatable {
    static let optimizedDirectoryName = "OptimizedVideos"
    static let postersDirectoryName = "Posters"
    /// Stills derived from posters (dimmed, or one display's slice of a
    /// panorama) for the system desktop picture. Rebuilt on demand.
    static let desktopPicturesDirectoryName = "DesktopPictures"

    let root: URL

    var assetsFile: URL { root.appendingPathComponent("assets.json") }
    var placementsFile: URL { root.appendingPathComponent("placements.json") }
    var bookmarksFile: URL { root.appendingPathComponent("bookmarks.json") }
    var playlistsFile: URL { root.appendingPathComponent("playlists.json") }
    var optimizedDirectory: URL { root.appendingPathComponent(Self.optimizedDirectoryName, isDirectory: true) }
    var postersDirectory: URL { root.appendingPathComponent(Self.postersDirectoryName, isDirectory: true) }
    var desktopPicturesDirectory: URL { root.appendingPathComponent(Self.desktopPicturesDirectoryName, isDirectory: true) }

    init(root: URL) {
        self.root = root
    }

    /// Resolves `Application Support/Wallpaper` (the directory name is kept for
    /// compatibility with existing installs) and creates the sub-directories.
    static func resolve(fileManager: FileManager = .default) throws -> StorageLocations {
        let locations = StorageLocations(root: try fileManager.wallpaperApplicationSupportDirectory())
        try locations.prepareDirectories(fileManager: fileManager)
        return locations
    }

    func prepareDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, optimizedDirectory, postersDirectory, desktopPicturesDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func url(forRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func existingURL(forRelativePath relativePath: String?, fileManager: FileManager = .default) -> URL? {
        guard let relativePath else { return nil }
        let url = url(forRelativePath: relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

/// A recoverable problem found while loading persisted state.
enum StorageIssue: Sendable, Equatable {
    case storageUnavailable(description: String)
    case corruptedFile(name: String, preservedAs: String?)

    var message: String {
        switch self {
        case let .storageUnavailable(description):
            return String(
                localized: "WallSync could not open its data folder, so changes will not be saved. \(description)"
            )
        case let .corruptedFile(name, preservedAs):
            if let preservedAs {
                return String(
                    localized: "The file “\(name)” was damaged and has been reset. A copy was kept as “\(preservedAs)”."
                )
            }
            return String(localized: "The file “\(name)” was damaged and has been reset.")
        }
    }
}

struct StoreLoadResult<Value: Sendable>: Sendable {
    var value: Value
    var issue: StorageIssue?
}

enum JSONFile {
    /// Loads `type` from `url`. A missing file yields `defaultValue`; an
    /// unreadable or undecodable file is moved aside (never deleted) and
    /// reported, so a corrupted catalog cannot prevent the app from opening.
    static func load<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL,
        defaultValue: Value,
        fileManager: FileManager = .default
    ) -> StoreLoadResult<Value> {
        guard fileManager.fileExists(atPath: url.path) else {
            return StoreLoadResult(value: defaultValue, issue: nil)
        }

        do {
            let data = try Data(contentsOf: url)
            return StoreLoadResult(value: try JSONDecoder().decode(type, from: data), issue: nil)
        } catch {
            let preserved = preserveCorruptedFile(at: url, fileManager: fileManager)
            return StoreLoadResult(
                value: defaultValue,
                issue: .corruptedFile(name: url.lastPathComponent, preservedAs: preserved?.lastPathComponent)
            )
        }
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func preserveCorruptedFile(at url: URL, fileManager: FileManager) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for attempt in 0..<20 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base).corrupt-\(stamp)\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path),
               (try? fileManager.moveItem(at: url, to: candidate)) != nil {
                return candidate
            }
        }
        return nil
    }
}
