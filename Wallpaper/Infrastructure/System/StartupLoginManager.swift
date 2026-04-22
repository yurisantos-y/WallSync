import Foundation
import ServiceManagement

enum StartupLoginState: String, Sendable {
    case enabled
    case disabled
    case requiresApproval
}

@MainActor
final class StartupLoginManager {
    func currentState() -> StartupLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        default:
            return .disabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
