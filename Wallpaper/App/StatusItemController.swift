import AppKit
import Foundation

@MainActor
final class StatusItemController: NSObject {
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Wallpaper")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Abrir ajustes", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Encerrar Wallpaper", action: #selector(quitApp), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu

        statusItem = item
    }

    @objc
    private func openSettings() {
        onOpenSettings?()
    }

    @objc
    private func quitApp() {
        onQuit?()
    }
}
