import Foundation

struct AppRuntimeState: Sendable {
    enum PowerSource: String, Sendable {
        case ac
        case battery
        case unknown
    }

    enum SleepState: String, Sendable {
        case awake
        case sleeping
    }

    var powerSource: PowerSource
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState
    var activeDisplays: [DisplayTarget]
    var fullscreenDisplayUUIDs: Set<String>
    var visibleSessions: Set<UUID>
    var sleepState: SleepState

    // States in which nobody can see the desktop. They suspend playback
    // unconditionally, regardless of the user's preferences.
    var isScreenLocked = false
    var isScreenSaverActive = false
    var displaysAsleep = false
    /// Another user is in front (fast user switching).
    var isSessionInactive = false

    /// The user paused every wallpaper from the menu bar.
    var isUserPaused = false
    /// A Focus filter asked for the wallpapers to be paused.
    var isFocusPaused = false
    /// The system is using the dark appearance.
    var isDarkAppearance = false
    /// System "Reduce motion" accessibility setting.
    var reduceMotionEnabled = false

    var isInvisibleToUser: Bool {
        sleepState == .sleeping || isScreenLocked || isScreenSaverActive || displaysAsleep || isSessionInactive
    }

    static let initial = AppRuntimeState(
        powerSource: .unknown,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.processInfo.thermalState,
        activeDisplays: [],
        fullscreenDisplayUUIDs: [],
        visibleSessions: [],
        sleepState: .awake
    )
}
