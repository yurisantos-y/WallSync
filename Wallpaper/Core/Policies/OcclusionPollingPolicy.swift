import Foundation

/// Decides whether the low-frequency window-list re-evaluation should run.
///
/// Maximizing a window or opening a borderless game produces no notification,
/// so coverage has to be re-checked periodically — but only while that check
/// can change something. When every session is held by a state that announces
/// its own end (lock, sleep, battery, thermal, user pause…) the app stays
/// completely idle.
enum OcclusionPollingPolicy {
    static let interval: TimeInterval = 3
    static let tolerance: TimeInterval = 1.5

    static func shouldPoll(sessions: [RenderSession]) -> Bool {
        sessions.contains { session in
            switch session.energyMode {
            case .animate:
                // Something may cover the desktop.
                return true
            case .suspend:
                // Something covering the desktop may go away.
                return session.modeReason == .occluded || session.modeReason == .fullscreen
            case .poster:
                return false
            }
        }
    }
}
