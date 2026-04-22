import AppKit
import ApplicationServices
import Foundation

@MainActor
final class SystemEventMonitor {
    enum Event {
        case displaysChanged
        case activeSpaceChanged
        case willSleep
        case didWake
        case powerStateChanged
        case thermalStateChanged
    }

    private var observers: [NSObjectProtocol] = []
    var handler: ((Event) -> Void)?
    private var isDisplayCallbackRegistered = false

    init(handler: ((Event) -> Void)? = nil) {
        self.handler = handler
    }

    func start() {
        stop()

        let notificationCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.displaysChanged)
                }
            }
        )

        registerDisplayCallback()

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.activeSpaceChanged)
                }
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.willSleep)
                }
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.didWake)
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.powerStateChanged)
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(.thermalStateChanged)
                }
            }
        )
    }

    func stop() {
        let notificationCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.forEach {
            notificationCenter.removeObserver($0)
            workspaceCenter.removeObserver($0)
        }
        observers.removeAll()
        unregisterDisplayCallback()
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
