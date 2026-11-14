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

/// Delivers a callback on the main run loop whenever the power source
/// changes (charger connected or disconnected, battery level updates).
/// `NSProcessInfoPowerStateDidChange` only covers Low Power Mode.
@MainActor
final class PowerSourceObserver {
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@MainActor () -> Void)?

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            // The source is scheduled on the main run loop.
            MainActor.assumeIsolated {
                observer.handler?()
            }
        }, context)?.takeRetainedValue() else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        handler = nil
    }
}
