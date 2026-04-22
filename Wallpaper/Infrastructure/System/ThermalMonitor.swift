import Foundation

struct ThermalMonitor {
    func currentThermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
