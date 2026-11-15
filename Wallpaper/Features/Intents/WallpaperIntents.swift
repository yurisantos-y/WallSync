import AppIntents
import Foundation

// Actions for the Shortcuts app. Every one of them runs in the background
// (the app's window is never brought forward) and goes through the
// coordinator, which resolves what each display shows and hands the result
// to the serialized session queue. No action touches sessions directly.

struct SetWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wallpaper"
    static let description = IntentDescription("Shows a wallpaper from your WallSync library on one display or on all of them.")
    static let openAppWhenRun = false

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity

    @Parameter(title: "Display", description: "Leave empty to use every display.")
    var display: DisplayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Set the wallpaper to \(\.$wallpaper)") {
            \.$display
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = try await AppIntentBridge.ready()
        try coordinator.perform(.setWallpaper(assetID: wallpaper.id, displayUUID: display?.id))
        return .result()
    }
}

struct ActivatePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Playlist"
    static let description = IntentDescription("Puts a WallSync playlist in rotation on one display or on all of them.")
    static let openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Display", description: "Leave empty to use every display.")
    var display: DisplayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start the playlist \(\.$playlist)") {
            \.$display
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = try await AppIntentBridge.ready()
        try coordinator.perform(.activatePlaylist(playlistID: playlist.id, displayUUID: display?.id))
        return .result()
    }
}

struct NextWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Wallpaper"
    static let description = IntentDescription("Moves the playlist in rotation on to its next wallpaper.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let coordinator = try await AppIntentBridge.ready()
        try coordinator.perform(.nextWallpaper)
        return .result()
    }
}

struct PauseWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Wallpapers"
    static let description = IntentDescription("Pauses every WallSync wallpaper on a still frame.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentBridge.ready().setUserPaused(true)
        return .result()
    }
}

struct ResumeWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Wallpapers"
    static let description = IntentDescription("Resumes the WallSync wallpapers after a pause.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentBridge.ready().setUserPaused(false)
        return .result()
    }
}

struct TogglePauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Wallpapers"
    static let description = IntentDescription("Pauses the WallSync wallpapers if they are playing, and resumes them if they are paused.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let coordinator = try await AppIntentBridge.ready()
        let paused = !coordinator.runtimeState.isUserPaused
        coordinator.setUserPaused(paused)
        return .result(value: paused)
    }
}

// MARK: - Focus filter

enum FocusWallpaperBehavior: String, AppEnum {
    case noChange
    case pause
    case wallpaper
    case playlist

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper Behavior"
    static let caseDisplayRepresentations: [FocusWallpaperBehavior: DisplayRepresentation] = [
        .noChange: "Leave as it is",
        .pause: "Pause the wallpapers",
        .wallpaper: "Use a wallpaper",
        .playlist: "Use a playlist"
    ]

    var behavior: FocusFilterBehavior {
        FocusFilterBehavior(rawValue: rawValue) ?? .noChange
    }
}

/// Configured in System Settings › Focus › Focus Filters. While the Focus is
/// on, the wallpapers are paused or replaced; when it ends the system calls
/// the filter again with its default values, which clears the override, and
/// the wallpapers the user assigned come back untouched.
struct WallSyncFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Wallpaper Behavior"
    static let description: IntentDescription? = IntentDescription(
        "Pauses the wallpapers, or shows a chosen wallpaper or playlist, while this Focus is on."
    )

    @Parameter(title: "While this Focus is on", default: .noChange)
    var behavior: FocusWallpaperBehavior

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity?

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity?

    var displayRepresentation: DisplayRepresentation {
        switch behavior {
        case .noChange:
            return DisplayRepresentation(title: "Wallpapers stay as they are")
        case .pause:
            return DisplayRepresentation(title: "Wallpapers are paused")
        case .wallpaper:
            return DisplayRepresentation(title: "Wallpaper", subtitle: LocalizedStringResource(String.LocalizationValue(wallpaper?.name ?? "")))
        case .playlist:
            return DisplayRepresentation(title: "Playlist", subtitle: LocalizedStringResource(String.LocalizationValue(playlist?.name ?? "")))
        }
    }

    /// The override this configuration stands for.
    var focusOverride: FocusOverride? {
        behavior.behavior.override(wallpaperID: wallpaper?.id, playlistID: playlist?.id)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AppIntentBridge.ready().setFocusOverride(focusOverride)
        return .result()
    }
}

// MARK: - Shortcuts shown without any setup

struct WallSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TogglePauseIntent(),
            phrases: [
                "Pause or resume \(.applicationName)",
                "Toggle \(.applicationName) wallpapers"
            ],
            shortTitle: "Pause or Resume",
            systemImageName: "playpause"
        )
        AppShortcut(
            intent: NextWallpaperIntent(),
            phrases: [
                "Next \(.applicationName) wallpaper",
                "Next wallpaper in \(.applicationName)"
            ],
            shortTitle: "Next Wallpaper",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: PauseWallpapersIntent(),
            phrases: ["Pause \(.applicationName) wallpapers"],
            shortTitle: "Pause Wallpapers",
            systemImageName: "pause"
        )
        AppShortcut(
            intent: ResumeWallpapersIntent(),
            phrases: ["Resume \(.applicationName) wallpapers"],
            shortTitle: "Resume Wallpapers",
            systemImageName: "play"
        )
    }
}
