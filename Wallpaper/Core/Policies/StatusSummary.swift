import Foundation

/// Reduces the sessions to the single state shown in the menu bar.
enum StatusSummary: Equatable, Sendable {
    case noWallpapers
    case pausedByUser
    case animating(count: Int, total: Int)
    /// Nothing is animating; `reason` is the most common cause.
    case idle(reason: SessionModeReason)

    static func make(sessions: [RenderSession], isUserPaused: Bool) -> StatusSummary {
        guard !sessions.isEmpty else {
            return isUserPaused ? .pausedByUser : .noWallpapers
        }
        if isUserPaused {
            return .pausedByUser
        }

        let animating = sessions.filter { $0.energyMode == .animate && $0.playbackState == .animating }.count
        if animating > 0 {
            return .animating(count: animating, total: sessions.count)
        }

        let reasons = Dictionary(grouping: sessions, by: \.modeReason).mapValues(\.count)
        let dominant = reasons.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }?.key ?? .none
        return .idle(reason: dominant)
    }
}
