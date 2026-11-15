import Foundation

struct UserPreferences: Codable, Hashable, Sendable {
    enum FallbackMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case balanced
        case batterySaver

        var id: String { rawValue }
    }

    /// Trade-off used when a video is optimized for playback.
    enum PlaybackQuality: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Up to 30 fps: lowest energy use.
        case efficiency
        /// Up to 60 fps: smoother motion, roughly twice the decode work.
        case smooth

        var id: String { rawValue }

        var maximumFrameRate: Double {
            switch self {
            case .efficiency: return 30
            case .smooth: return 60
            }
        }
    }

    var launchAtLogin: Bool
    var startOnLaunch: Bool
    var reduceOnBattery: Bool
    var pauseWhenFullscreen: Bool
    var pauseWhenOccluded: Bool
    var fallbackMode: FallbackMode
    var playbackQuality: PlaybackQuality = .efficiency
    /// Show a still frame while the system "Reduce motion" setting is on.
    var pauseWhenReduceMotion: Bool = false

    static let defaultValue = UserPreferences(
        launchAtLogin: false,
        startOnLaunch: true,
        reduceOnBattery: true,
        pauseWhenFullscreen: true,
        pauseWhenOccluded: true,
        fallbackMode: .balanced
    )
}

extension UserPreferences {
    /// Tolerant decoding: preferences saved by any earlier version keep
    /// loading, and fields they do not have take their default value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserPreferences.defaultValue

        self.init(
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin,
            startOnLaunch: try container.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? defaults.startOnLaunch,
            reduceOnBattery: try container.decodeIfPresent(Bool.self, forKey: .reduceOnBattery) ?? defaults.reduceOnBattery,
            pauseWhenFullscreen: try container.decodeIfPresent(Bool.self, forKey: .pauseWhenFullscreen) ?? defaults.pauseWhenFullscreen,
            pauseWhenOccluded: try container.decodeIfPresent(Bool.self, forKey: .pauseWhenOccluded) ?? defaults.pauseWhenOccluded,
            fallbackMode: (try? container.decodeIfPresent(FallbackMode.self, forKey: .fallbackMode)) ?? defaults.fallbackMode,
            playbackQuality: (try? container.decodeIfPresent(PlaybackQuality.self, forKey: .playbackQuality)) ?? defaults.playbackQuality,
            pauseWhenReduceMotion: try container.decodeIfPresent(Bool.self, forKey: .pauseWhenReduceMotion) ?? defaults.pauseWhenReduceMotion
        )
    }
}
