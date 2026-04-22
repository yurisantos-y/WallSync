import Foundation

struct RenderSession: Identifiable, Hashable, Sendable {
    enum WindowState: String, Codable, Sendable {
        case visible
        case hidden
        case suspended
    }

    enum PlaybackState: String, Codable, Sendable {
        case idle
        case preparing
        case animating
        case poster
        case paused
        case failed
    }

    enum EnergyMode: String, Codable, Sendable {
        case animate
        case poster
        case suspend
    }

    var id: UUID
    var displayTarget: DisplayTarget
    var assetID: UUID
    var windowState: WindowState
    var playbackState: PlaybackState
    var energyMode: EnergyMode
    var startedAt: Date
    var lastVisibilityChange: Date
}
