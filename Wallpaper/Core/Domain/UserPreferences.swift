import Foundation

struct UserPreferences: Codable, Hashable, Sendable {
    enum FallbackMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case balanced
        case batterySaver

        var id: String { rawValue }
    }

    var launchAtLogin: Bool
    var startOnLaunch: Bool
    var reduceOnBattery: Bool
    var pauseWhenFullscreen: Bool
    var pauseWhenOccluded: Bool
    var fallbackMode: FallbackMode

    static let defaultValue = UserPreferences(
        launchAtLogin: false,
        startOnLaunch: true,
        reduceOnBattery: true,
        pauseWhenFullscreen: true,
        pauseWhenOccluded: true,
        fallbackMode: .balanced
    )
}
