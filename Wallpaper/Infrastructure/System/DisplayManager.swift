import AppKit
import Foundation

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
}

@MainActor
final class NativeDesktopPictureManager {
    private struct AppliedAssignment: Equatable {
        var posterURL: URL
        var contentMode: WallpaperPlacement.ContentMode
    }

    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let reconciliationPolicy = SessionReconciliationPolicy()
    private var lastAppliedAssignments: [String: AppliedAssignment] = [:]

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func syncDesktopPictures(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement]
    ) throws {
        let supportDirectory = try fileManager.wallpaperApplicationSupportDirectory()
        let assignments = Self.desiredAssignments(
            displays: displays,
            assets: assets,
            placements: placements,
            reconciliationPolicy: reconciliationPolicy
        )
        let activeDisplayUUIDs = Set(assignments.map(\.displayUUID))
        var failures: [Error] = []

        for assignment in assignments {
            guard let screen = Self.screen(matching: assignment.cgDisplayID) else { continue }

            let posterURL = supportDirectory.appendingPathComponent(assignment.posterImageRelativePath)
            guard fileManager.fileExists(atPath: posterURL.path) else { continue }

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

        if !failures.isEmpty {
            throw NativeDesktopPictureError.failedToApplyWallpaper
        }
    }

    nonisolated static func desiredAssignments(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement],
        reconciliationPolicy: SessionReconciliationPolicy = SessionReconciliationPolicy()
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
                contentMode: desiredSession.placement.contentMode
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

enum NativeDesktopPictureError: LocalizedError {
    case failedToApplyWallpaper

    var errorDescription: String? {
        switch self {
        case .failedToApplyWallpaper:
            return "Nao foi possivel atualizar o wallpaper estatico do macOS."
        }
    }
}
