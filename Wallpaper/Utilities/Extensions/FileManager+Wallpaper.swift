import AppKit
import Foundation

extension FileManager {
    func wallpaperApplicationSupportDirectory() throws -> URL {
        let root = try url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Wallpaper", isDirectory: true)
        if !fileExists(atPath: directory.path) {
            try createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
