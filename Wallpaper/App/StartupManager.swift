import Foundation

@MainActor
final class StartupManager {
    enum RestoreTrigger {
        case appLaunch
        case displayChange
        case activeSpaceChange
        case wake
        case powerChange
        case thermalChange
        case manual
    }

    func delay(for trigger: RestoreTrigger) -> Duration {
        switch trigger {
        case .appLaunch:
            return .milliseconds(450)
        case .displayChange:
            return .milliseconds(350)
        case .activeSpaceChange:
            return .milliseconds(180)
        case .wake:
            return .seconds(1)
        case .powerChange, .thermalChange:
            return .milliseconds(120)
        case .manual:
            return .zero
        }
    }

    func waitBeforeRestore(for trigger: RestoreTrigger) async {
        let delay = delay(for: trigger)
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
    }
}
