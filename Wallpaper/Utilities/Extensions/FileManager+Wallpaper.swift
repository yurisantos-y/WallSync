import Foundation

extension FileManager {
    /// `Application Support/Wallpaper`. The directory keeps the project's
    /// original name; renaming it would require migrating existing installs.
    func wallpaperApplicationSupportDirectory() throws -> URL {
        let root = try url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Wallpaper", isDirectory: true)
        if !fileExists(atPath: directory.path) {
            try createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
