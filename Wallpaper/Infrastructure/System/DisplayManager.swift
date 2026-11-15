import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class DisplayManager: DisplayProviding {
    func currentDisplays() -> [DisplayTarget] {
        let separateSpaces = NSScreen.screensHaveSeparateSpaces

        return NSScreen.screens.compactMap { screen in
            guard let displayID = screen.cgDirectDisplayID else {
                return nil
            }

            return DisplayTarget(
                displayUUID: DisplayIdentity.uuidString(for: displayID),
                cgDisplayID: displayID,
                localizedName: screen.localizedName,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor,
                isPrimary: screen == NSScreen.screens.first,
                maximumFramesPerSecond: screen.maximumFramesPerSecond,
                hasSeparateSpaceContext: separateSpaces
            )
        }
    }
}

struct NativeDesktopPictureAssignment: Equatable, Hashable, Sendable {
    var displayUUID: String
    var cgDisplayID: CGDirectDisplayID
    var posterImageRelativePath: String
    var contentMode: WallpaperPlacement.ContentMode
    /// The same dimming the wallpaper window shows, so pausing, switching
    /// Spaces and Mission Control show no jump in brightness.
    var dimming: DimOverlay? = nil
    /// The display's slice of a panorama: unit rectangle, origin top-left.
    var crop: CGRect? = nil

    /// The stored poster cannot be used as is.
    var needsDerivedImage: Bool { dimming != nil || crop != nil }

    /// Stable across launches, so a derived still is rendered only once.
    var derivedFileName: String {
        var parts = [((posterImageRelativePath as NSString).lastPathComponent as NSString).deletingPathExtension]
        if let dimming {
            let channels = [dimming.color.red, dimming.color.green, dimming.color.blue]
                .map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }
                .joined()
            parts.append("d\(Int((dimming.opacity * 1000).rounded()))-\(channels)")
        }
        if let crop {
            let values = [crop.minX, crop.minY, crop.width, crop.height].map { String(Int(($0 * 10_000).rounded())) }
            parts.append("c" + values.joined(separator: "_"))
        }
        return parts.joined(separator: "-") + ".heic"
    }
}

@MainActor
final class NativeDesktopPictureManager {
    private struct AppliedAssignment: Equatable {
        var posterURL: URL
        var contentMode: WallpaperPlacement.ContentMode
    }

    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let storage: StorageLocations
    private let reconciliationPolicy = SessionReconciliationPolicy()
    private var lastAppliedAssignments: [String: AppliedAssignment] = [:]
    private var lastAssignments: [NativeDesktopPictureAssignment] = []
    /// Derived stills being rendered off the main thread, by file name.
    private var renderTasks: [String: Task<Void, Never>] = [:]

    init(
        storage: StorageLocations,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.storage = storage
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func syncDesktopPictures(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement],
        dimming: DimmingSettings = .off,
        isDarkAppearance: Bool = false
    ) throws {
        lastAssignments = Self.desiredAssignments(
            displays: displays,
            assets: assets,
            placements: placements,
            reconciliationPolicy: reconciliationPolicy,
            dimming: dimming,
            isDarkAppearance: isDarkAppearance
        )
        try apply(lastAssignments)
    }

    private func apply(_ assignments: [NativeDesktopPictureAssignment]) throws {
        let activeDisplayUUIDs = Set(assignments.map(\.displayUUID))
        var failures: [Error] = []

        for assignment in assignments {
            guard let screen = Self.screen(matching: assignment.cgDisplayID) else { continue }

            let sourceURL = storage.url(forRelativePath: assignment.posterImageRelativePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let posterURL: URL
            if assignment.needsDerivedImage {
                let derivedURL = storage.desktopPicturesDirectory.appendingPathComponent(assignment.derivedFileName)
                guard fileManager.fileExists(atPath: derivedURL.path) else {
                    // Rendered in the background; applied when it is ready.
                    renderDerivedImage(for: assignment, from: sourceURL, to: derivedURL)
                    continue
                }
                posterURL = derivedURL
            } else {
                posterURL = sourceURL
            }

            let appliedAssignment = AppliedAssignment(
                posterURL: posterURL,
                contentMode: assignment.contentMode
            )

            if lastAppliedAssignments[assignment.displayUUID] == appliedAssignment,
               workspace.desktopImageURL(for: screen)?.resolvingSymlinksInPath() == posterURL.resolvingSymlinksInPath() {
                continue
            }

            do {
                try workspace.setDesktopImageURL(
                    posterURL,
                    for: screen,
                    options: Self.desktopImageOptions(for: assignment.contentMode)
                )
                lastAppliedAssignments[assignment.displayUUID] = appliedAssignment
            } catch {
                failures.append(error)
            }
        }

        lastAppliedAssignments = lastAppliedAssignments.filter { activeDisplayUUIDs.contains($0.key) }
        removeUnusedDerivedImages(keeping: assignments)

        if !failures.isEmpty {
            throw NativeDesktopPictureError.failedToApplyWallpaper
        }
    }

    private func renderDerivedImage(for assignment: NativeDesktopPictureAssignment, from sourceURL: URL, to derivedURL: URL) {
        let name = assignment.derivedFileName
        guard renderTasks[name] == nil else { return }

        let dimming = assignment.dimming
        let crop = assignment.crop
        renderTasks[name] = Task { [weak self] in
            let succeeded = await Task.detached(priority: .utility) {
                DerivedPosterRenderer.render(from: sourceURL, to: derivedURL, dimming: dimming, crop: crop)
            }.value

            guard let self else { return }
            self.renderTasks[name] = nil
            // Only apply if this still is still wanted.
            guard succeeded, self.lastAssignments.contains(where: { $0.derivedFileName == name }) else { return }
            do {
                try self.apply(self.lastAssignments)
            } catch {
                Log.session.error("derived desktop picture could not be applied: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Derived stills are cheap to rebuild; only the ones in use are kept.
    private func removeUnusedDerivedImages(keeping assignments: [NativeDesktopPictureAssignment]) {
        let directory = storage.desktopPicturesDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path), !names.isEmpty else { return }
        var keep = Set(assignments.filter(\.needsDerivedImage).map(\.derivedFileName))
        keep.formUnion(renderTasks.keys)
        keep.formUnion(lastAppliedAssignments.values.map(\.posterURL.lastPathComponent))
        for name in names where !keep.contains(name) && !name.hasPrefix(".") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    nonisolated static func desiredAssignments(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement],
        reconciliationPolicy: SessionReconciliationPolicy = SessionReconciliationPolicy(),
        dimming: DimmingSettings = .off,
        isDarkAppearance: Bool = false
    ) -> [NativeDesktopPictureAssignment] {
        reconciliationPolicy.desiredSessions(
            displays: displays,
            assets: assets,
            placements: placements
        ).compactMap { desiredSession in
            guard let posterImageRelativePath = desiredSession.asset.posterImageRelativePath else {
                return nil
            }

            return NativeDesktopPictureAssignment(
                displayUUID: desiredSession.display.displayUUID,
                cgDisplayID: desiredSession.display.cgDisplayID,
                posterImageRelativePath: posterImageRelativePath,
                contentMode: desiredSession.placement.contentMode,
                dimming: DimmingPolicy.overlay(
                    for: desiredSession.asset,
                    settings: dimming,
                    isDarkAppearance: isDarkAppearance
                )
            )
        }
    }

    private static func screen(matching displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.cgDirectDisplayID == displayID }
    }

    private static func desktopImageOptions(
        for contentMode: WallpaperPlacement.ContentMode
    ) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: contentMode == .aspectFill
        ]
    }
}

/// Renders the still the system shows as desktop picture when the stored
/// poster cannot be used directly: with the dimming overlay composited in,
/// and / or cut down to one display's slice of a panorama.
enum DerivedPosterRenderer {
    /// The same result the wallpaper window shows: the poster with `dimming`
    /// laid over it, blended the way Core Animation blends an sRGB layer.
    static func image(from poster: CGImage, dimming: DimOverlay?, crop: CGRect?) -> CGImage? {
        var source = poster
        if let crop {
            let pixels = CGRect(
                x: (crop.minX * CGFloat(poster.width)).rounded(),
                y: (crop.minY * CGFloat(poster.height)).rounded(),
                width: (crop.width * CGFloat(poster.width)).rounded(),
                height: (crop.height * CGFloat(poster.height)).rounded()
            ).intersection(CGRect(x: 0, y: 0, width: poster.width, height: poster.height))
            guard !pixels.isEmpty, let cropped = poster.cropping(to: pixels) else { return nil }
            source = cropped
        }

        guard let dimming else { return source }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: bounds)
        context.setFillColor(
            CGColor(srgbRed: dimming.color.red, green: dimming.color.green, blue: dimming.color.blue, alpha: dimming.opacity)
        )
        context.fill(bounds)
        return context.makeImage()
    }

    @discardableResult
    static func render(from sourceURL: URL, to destinationURL: URL, dimming: DimOverlay?, crop: CGRect?) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let poster = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = image(from: poster, dimming: dimming, crop: crop) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try PosterCacheStore.write(image, to: destinationURL, type: .heic, quality: 0.9)
            return true
        } catch {
            return false
        }
    }
}

enum NativeDesktopPictureError: LocalizedError {
    case failedToApplyWallpaper

    var errorDescription: String? {
        switch self {
        case .failedToApplyWallpaper:
            return String(localized: "The static macOS wallpaper could not be updated.")
        }
    }
}
