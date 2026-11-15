import SwiftUI

// Localized labels for runtime state shown in the interface.

extension RenderSession.PlaybackState {
    var localizedLabel: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .preparing: return String(localized: "Preparing")
        case .animating: return String(localized: "Animating")
        case .poster: return String(localized: "Still frame")
        case .paused: return String(localized: "Paused")
        case .failed: return String(localized: "Failed")
        }
    }

    var color: Color {
        switch self {
        case .animating: return .green
        case .poster: return .orange
        case .paused, .idle: return .gray
        case .preparing: return .blue
        case .failed: return .red
        }
    }
}

extension RenderSession.EnergyMode {
    var localizedLabel: String {
        switch self {
        case .animate: return String(localized: "Animating")
        case .poster: return String(localized: "Still frame")
        case .suspend: return String(localized: "Suspended")
        }
    }

    var color: Color {
        switch self {
        case .animate: return .green
        case .poster: return .orange
        case .suspend: return .gray
        }
    }
}

extension Optional where Wrapped == RenderSession.PlaybackSource {
    var localizedLabel: String {
        switch self {
        case .optimized?: return String(localized: "Optimized copy")
        case .original?: return String(localized: "Original file")
        case nil: return String(localized: "Not loaded")
        }
    }
}

extension SessionModeReason {
    var localizedLabel: String {
        switch self {
        case .none: return String(localized: "None")
        case .screenLocked: return String(localized: "Screen locked")
        case .screenSaver: return String(localized: "Screen saver active")
        case .displaysAsleep: return String(localized: "Displays asleep")
        case .systemSleeping: return String(localized: "Mac sleeping")
        case .sessionInactive: return String(localized: "Another user is active")
        case .userPaused: return String(localized: "Paused by you")
        case .focusFilter: return String(localized: "Paused by a Focus")
        case .fullscreen: return String(localized: "Fullscreen app")
        case .occluded: return String(localized: "Desktop covered")
        case .reduceMotion: return String(localized: "Reduce Motion is on")
        case .thermalPressure: return String(localized: "Thermal pressure")
        case .battery: return String(localized: "On battery")
        case .lowPowerMode: return String(localized: "Low Power Mode")
        case .batterySaverSecondaryDisplay: return String(localized: "Battery saver on secondary display")
        }
    }
}

extension AppRuntimeState.PowerSource {
    var localizedLabel: String {
        switch self {
        case .ac: return String(localized: "Power adapter")
        case .battery: return String(localized: "Battery")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ProcessInfo.ThermalState {
    var localizedLabel: String {
        switch self {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Slightly elevated")
        case .serious: return String(localized: "High")
        case .critical: return String(localized: "Critical")
        @unknown default: return String(localized: "Unknown")
        }
    }
}

extension StatusSummary {
    var localizedLabel: String {
        switch self {
        case .noWallpapers:
            return String(localized: "No wallpaper running")
        case .pausedByUser:
            return String(localized: "Paused")
        case let .animating(count, total):
            return count == total
                ? String(localized: "Animating on \(count) displays")
                : String(localized: "Animating on \(count) of \(total) displays")
        case let .idle(reason):
            return reason == .none
                ? String(localized: "Not animating")
                : String(localized: "Not animating: \(reason.localizedLabel)")
        }
    }
}
