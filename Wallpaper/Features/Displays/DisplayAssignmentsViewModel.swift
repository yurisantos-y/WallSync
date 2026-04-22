import Foundation
import Observation

@MainActor
@Observable
final class DisplayAssignmentsViewModel {
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func assignedAssetID(for display: DisplayTarget) -> UUID? {
        coordinator.assignedAssetID(for: display)
    }

    func contentMode(for display: DisplayTarget) -> WallpaperPlacement.ContentMode {
        coordinator.contentMode(for: display)
    }
}
