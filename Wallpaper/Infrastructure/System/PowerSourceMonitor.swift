import Foundation
import IOKit.ps

struct PowerSourceMonitor {
    func currentPowerSource() -> AppRuntimeState.PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(info, powerSource)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }

            if state == kIOPSACPowerValue {
                return .ac
            }

            if state == kIOPSBatteryPowerValue {
                return .battery
            }
        }

        return .unknown
    }
}
