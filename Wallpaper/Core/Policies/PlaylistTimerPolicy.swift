import Foundation

/// When the schedule's single timer may exist.
///
/// A wallpaper is on screen all day, so waking the process is only
/// acceptable when it changes something a person can see. There is exactly
/// one timer, armed for the next change, and none at all when no playlist
/// depends on the clock or when nobody can see the desktop. In the second
/// case the right item is computed from the clock when the desktop comes
/// back; nothing is counted or caught up.
enum PlaylistTimerPolicy {
    struct Schedule: Equatable, Sendable {
        var fireDate: Date
        /// How far the system may delay the wake-up to batch it with others.
        var tolerance: TimeInterval
    }

    /// Whether anybody can see a desktop: the screen is on and unlocked, and
    /// at least one wallpaper window is not suspended (covered, fullscreen).
    static func desktopIsVisible(runtimeState: AppRuntimeState, sessions: [RenderSession]) -> Bool {
        guard !runtimeState.isInvisibleToUser else { return false }
        return sessions.isEmpty || sessions.contains { $0.energyMode != .suspend }
    }

    static func schedule(nextChange: Date?, desktopIsVisible: Bool, now: Date) -> Schedule? {
        guard let nextChange, desktopIsVisible else { return nil }
        let delay = max(nextChange.timeIntervalSince(now), 0)
        return Schedule(fireDate: nextChange, tolerance: min(max(delay * 0.1, 1), 60))
    }
}
