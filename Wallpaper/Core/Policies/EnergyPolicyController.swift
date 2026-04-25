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
}

enum SessionMode: String, Sendable {
    case animate
    case poster
    case suspend
}

final class EnergyPolicyController {
    func mode(for context: SystemContext, preferences: UserPreferences) -> SessionMode {
        if context.isFullscreen && preferences.pauseWhenFullscreen {
            return .suspend
        }

        if context.isOccluded && preferences.pauseWhenOccluded {
            return .suspend
        }

        if context.thermalState == .critical {
            return .poster
        }

        if context.thermalState == .serious && context.assetIsHeavy {
            return .poster
        }

        if context.onBattery && preferences.reduceOnBattery && context.assetIsHeavy {
            return .poster
        }

        if context.lowPowerMode && context.assetIsHeavy {
            return .poster
        }

        if context.onBattery && context.activeDisplayCount > 1 && context.assetIsHeavy && !context.isPrimaryDisplay {
            return .poster
        }

        if preferences.fallbackMode == .batterySaver && context.onBattery && !context.isPrimaryDisplay {
            return .poster
        }

        return .animate
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

        return nil
    }
}
