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
        if context.thermalState == .critical {
            return true
        }

        if context.thermalState == .serious && context.assetIsHeavy {
            return true
        }

        guard preferences.fallbackMode == .batterySaver else {
            return false
        }

        return context.onBattery || context.lowPowerMode || context.assetIsHeavy || context.activeDisplayCount > 1
    }

    func suspendedPlaybackGracePeriod(for context: SystemContext, preferences: UserPreferences) -> Duration {
        if context.thermalState == .critical {
            return .seconds(2)
        }

        if context.thermalState == .serious && context.assetIsHeavy {
            return .seconds(6)
        }

        if preferences.fallbackMode == .batterySaver {
            if context.onBattery && context.assetIsHeavy {
                return .seconds(4)
            }

            if context.onBattery || context.lowPowerMode {
                return .seconds(8)
            }

            return .seconds(12)
        }

        return .seconds(20)
    }
}
