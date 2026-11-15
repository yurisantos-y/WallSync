import Foundation

struct SystemContext: Sendable {
    var onBattery: Bool
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState
    var isOccluded: Bool
    var isFullscreen: Bool
    var assetIsHeavy: Bool
    var isPrimaryDisplay: Bool
    var activeDisplayCount: Int

    // Nobody can see the desktop in these states.
    var isSystemSleeping = false
    var isScreenLocked = false
    var displaysAsleep = false
    var isScreenSaverActive = false
    var isSessionInactive = false

    var isUserPaused = false
    var isFocusPaused = false
    var reduceMotionEnabled = false

    var isInvisibleToUser: Bool {
        isSystemSleeping || isScreenLocked || displaysAsleep || isScreenSaverActive || isSessionInactive
    }
}

enum SessionMode: String, Sendable {
    case animate
    case poster
    case suspend
}

/// Why a session is in its current mode; shown in diagnostics and logs.
enum SessionModeReason: String, Sendable, CaseIterable {
    case none
    case screenLocked
    case screenSaver
    case displaysAsleep
    case systemSleeping
    case sessionInactive
    case userPaused
    case focusFilter
    case fullscreen
    case occluded
    case reduceMotion
    case thermalPressure
    case battery
    case lowPowerMode
    case batterySaverSecondaryDisplay
}

struct SessionModeDecision: Equatable, Sendable {
    var mode: SessionMode
    var reason: SessionModeReason
}

final class EnergyPolicyController: Sendable {
    func mode(for context: SystemContext, preferences: UserPreferences) -> SessionMode {
        decision(for: context, preferences: preferences).mode
    }

    func decision(for context: SystemContext, preferences: UserPreferences) -> SessionModeDecision {
        // Unconditional: when nobody can see the desktop no frame is decoded,
        // whatever the preferences say.
        if context.isSystemSleeping {
            return SessionModeDecision(mode: .suspend, reason: .systemSleeping)
        }

        if context.isScreenLocked {
            return SessionModeDecision(mode: .suspend, reason: .screenLocked)
        }

        if context.displaysAsleep {
            return SessionModeDecision(mode: .suspend, reason: .displaysAsleep)
        }

        if context.isScreenSaverActive {
            return SessionModeDecision(mode: .suspend, reason: .screenSaver)
        }

        if context.isSessionInactive {
            return SessionModeDecision(mode: .suspend, reason: .sessionInactive)
        }

        if context.isUserPaused {
            return SessionModeDecision(mode: .poster, reason: .userPaused)
        }

        if context.isFocusPaused {
            return SessionModeDecision(mode: .poster, reason: .focusFilter)
        }

        if context.isFullscreen && preferences.pauseWhenFullscreen {
            return SessionModeDecision(mode: .suspend, reason: .fullscreen)
        }

        if context.isOccluded && preferences.pauseWhenOccluded {
            return SessionModeDecision(mode: .suspend, reason: .occluded)
        }

        if context.reduceMotionEnabled && preferences.pauseWhenReduceMotion {
            return SessionModeDecision(mode: .poster, reason: .reduceMotion)
        }

        if context.thermalState == .critical {
            return SessionModeDecision(mode: .poster, reason: .thermalPressure)
        }

        if context.thermalState == .serious && context.assetIsHeavy {
            return SessionModeDecision(mode: .poster, reason: .thermalPressure)
        }

        if context.onBattery && preferences.reduceOnBattery && context.assetIsHeavy {
            return SessionModeDecision(mode: .poster, reason: .battery)
        }

        if context.lowPowerMode && context.assetIsHeavy {
            return SessionModeDecision(mode: .poster, reason: .lowPowerMode)
        }

        if context.onBattery && context.activeDisplayCount > 1 && context.assetIsHeavy && !context.isPrimaryDisplay {
            return SessionModeDecision(mode: .poster, reason: .battery)
        }

        if preferences.fallbackMode == .batterySaver && context.onBattery && !context.isPrimaryDisplay {
            return SessionModeDecision(mode: .poster, reason: .batterySaverSecondaryDisplay)
        }

        return SessionModeDecision(mode: .animate, reason: .none)
    }

    func shouldUnloadSuspendedPlayback(for context: SystemContext, preferences: UserPreferences) -> Bool {
        shouldUnloadPlayback(for: .suspend, context: context, preferences: preferences)
    }

    func suspendedPlaybackGracePeriod(for context: SystemContext, preferences: UserPreferences) -> Duration {
        playbackUnloadGracePeriod(for: .suspend, context: context, preferences: preferences) ?? .seconds(20)
    }

    func shouldUnloadPlayback(
        for mode: SessionMode,
        context: SystemContext,
        preferences: UserPreferences
    ) -> Bool {
        playbackUnloadGracePeriod(for: mode, context: context, preferences: preferences) != nil
    }

    func playbackUnloadGracePeriod(
        for mode: SessionMode,
        context: SystemContext,
        preferences: UserPreferences
    ) -> Duration? {
        guard mode == .poster || mode == .suspend else {
            return nil
        }

        if context.thermalState == .critical {
            return .seconds(2)
        }

        if context.thermalState == .serious && context.assetIsHeavy {
            return .seconds(6)
        }

        if (context.lowPowerMode || context.onBattery) && context.assetIsHeavy {
            return .seconds(8)
        }

        if preferences.fallbackMode == .batterySaver && !context.isPrimaryDisplay {
            return .seconds(12)
        }

        // Locked, asleep or switched away while on battery: the pipeline is
        // unlikely to be needed soon, so its memory and decoder are released.
        if context.isInvisibleToUser && (context.onBattery || context.lowPowerMode) {
            return .seconds(30)
        }

        return nil
    }
}
