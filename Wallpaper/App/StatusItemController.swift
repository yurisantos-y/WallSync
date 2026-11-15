import AppKit
import Foundation

/// Menu bar item: quick pause / resume, a one-line status and the usual
/// entries. The menu is refreshed each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Status {
        var isPaused: Bool
        var summary: String
        var hasWallpapers: Bool
    }

    var onOpenSettings: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onQuit: (() -> Void)?
    var statusProvider: (() -> Status)?

    private var statusItem: NSStatusItem?
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("WallSync")
        item.button?.toolTip = "WallSync"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: String(localized: "Open WallSync…"), action: #selector(openSettings), keyEquivalent: ",")
        )
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit WallSync"), action: #selector(quitApp), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu

        statusItem = item
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    /// Updates the menu and the icon from the current state.
    func refresh() {
        let status = statusProvider?() ?? Status(isPaused: false, summary: "", hasWallpapers: false)
        summaryItem.title = status.summary
        pauseItem.title = status.isPaused
            ? String(localized: "Resume all wallpapers")
            : String(localized: "Pause all wallpapers")
        pauseItem.isEnabled = status.hasWallpapers || status.isPaused
        // A dimmed icon says "paused" without relying on colour.
        statusItem?.button?.appearsDisabled = status.isPaused
    }

    @objc
    private func openSettings() {
        onOpenSettings?()
    }

    @objc
    private func togglePause() {
        onTogglePause?()
    }

    @objc
    private func quitApp() {
        onQuit?()
    }

    /// A template image: the system tints it for light and dark menu bars
    /// and for the translucent bar over any wallpaper.
    private static func statusBarImage() -> NSImage {
        let image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle.fill",
            accessibilityDescription: "WallSync"
        ) ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "WallSync") ?? NSImage()
        image.isTemplate = true
        return image
    }
}
