import AppKit
import ApplicationServices

extension NSScreen {
    var cgDirectDisplayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

enum DisplayIdentity {
    static func uuidString(for displayID: CGDirectDisplayID) -> String {
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(nil, uuidRef) as String
    }
}
