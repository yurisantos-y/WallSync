import AppKit
import ApplicationServices
import Foundation

@MainActor
final class SystemEventMonitor {
    enum Event: Equatable {
        case displaysChanged
        case activeSpaceChanged
        case applicationActivated
        case willSleep
        case didWake
        case powerStateChanged
        case thermalStateChanged
        case screenLockChanged(isLocked: Bool)
        case screenSaverChanged(isActive: Bool)
        case displaySleepChanged(isAsleep: Bool)
        case sessionActiveChanged(isActive: Bool)
        case accessibilityOptionsChanged
        /// The system switched between the light and dark appearance.
        case appearanceChanged
        /// The clock was set, or the time zone changed.
        case clockChanged
    }

    /// Whether the system is using the dark appearance right now.
    static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var handler: ((Event) -> Void)?
    private var isDisplayCallbackRegistered = false
    private let powerSourceObserver = PowerSourceObserver()
    private var lastPowerSource: AppRuntimeState.PowerSource?

    init(handler: ((Event) -> Void)? = nil) {
        self.handler = handler
    }

    /// Whether the login session's screen is locked right now.
    static var isScreenCurrentlyLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func start() {
        stop()

        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()

        observe(appCenter, NSApplication.didChangeScreenParametersNotification, .displaysChanged)
        registerDisplayCallback()

        // IOKit fires for every battery-level update; only a change of source
        // (charger connected or disconnected) is an event for the app.
        lastPowerSource = PowerSourceMonitor().currentPowerSource()
        powerSourceObserver.start { [weak self] in
            guard let self else { return }
            let current = PowerSourceMonitor().currentPowerSource()
            guard current != self.lastPowerSource else { return }
            self.lastPowerSource = current
            self.emit(.powerStateChanged)
        }

        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged)
        observe(workspaceCenter, NSWorkspace.didActivateApplicationNotification, .applicationActivated)
        observe(workspaceCenter, NSWorkspace.willSleepNotification, .willSleep)
        observe(workspaceCenter, NSWorkspace.didWakeNotification, .didWake)
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification, .displaySleepChanged(isAsleep: true))
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification, .displaySleepChanged(isAsleep: false))
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .sessionActiveChanged(isActive: false))
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActiveChanged(isActive: true))
        observe(
            workspaceCenter,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            .accessibilityOptionsChanged
        )

        observe(appCenter, NSNotification.Name.NSProcessInfoPowerStateDidChange, .powerStateChanged)
        observe(appCenter, ProcessInfo.thermalStateDidChangeNotification, .thermalStateChanged)

        observe(distributedCenter, Notification.Name("AppleInterfaceThemeChangedNotification"), .appearanceChanged)
        observe(appCenter, NSNotification.Name.NSSystemClockDidChange, .clockChanged)
        observe(appCenter, NSNotification.Name.NSSystemTimeZoneDidChange, .clockChanged)

        observe(distributedCenter, Notification.Name("com.apple.screenIsLocked"), .screenLockChanged(isLocked: true))
        observe(distributedCenter, Notification.Name("com.apple.screenIsUnlocked"), .screenLockChanged(isLocked: false))
        observe(distributedCenter, Notification.Name("com.apple.screensaver.didstart"), .screenSaverChanged(isActive: true))
        observe(distributedCenter, Notification.Name("com.apple.screensaver.didstop"), .screenSaverChanged(isActive: false))
    }

    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        unregisterDisplayCallback()
        powerSourceObserver.stop()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(event)
            }
        }
        observers.append((center, token))
    }

    private func emit(_ event: Event) {
        handler?(event)
    }

    private func registerDisplayCallback() {
        guard !isDisplayCallbackRegistered else { return }
        CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        isDisplayCallbackRegistered = true
    }

    private func unregisterDisplayCallback() {
        guard isDisplayCallbackRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        isDisplayCallbackRegistered = false
    }

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }
        let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        Task { @MainActor in
            monitor.emit(.displaysChanged)
        }
    }
}
