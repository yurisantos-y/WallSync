import Foundation

/// Remembers whether the initial "restore wallpapers at launch" decision was
/// made, independently of which trigger happens to run the first reconcile.
///
/// With "start wallpapers when the app opens" turned off, system events
/// (display, power, Space changes) must not start the wallpapers; only an
/// explicit user action does.
struct StartupRestoreGate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// No reconcile has run yet since launch.
        case pending
        /// Launch restore was skipped because the preference is off.
        case suppressed
        /// Wallpapers are allowed to run.
        case open
    }

    private(set) var phase: Phase = .pending

    /// Returns whether a reconcile caused by `isUserInitiated` may start sessions.
    mutating func shouldReconcile(isUserInitiated: Bool, startOnLaunch: Bool) -> Bool {
        if isUserInitiated {
            phase = .open
            return true
        }

        switch phase {
        case .open:
            return true
        case .pending:
            phase = startOnLaunch ? .open : .suppressed
            return startOnLaunch
        case .suppressed:
            return false
        }
    }
}
