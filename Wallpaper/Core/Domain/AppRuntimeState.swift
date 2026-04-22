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
