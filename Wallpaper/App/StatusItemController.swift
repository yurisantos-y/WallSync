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
        item.button?.image = statusBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Abrir ajustes", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Encerrar WallSync", action: #selector(quitApp), keyEquivalent: "q"))

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

    private func statusBarImage() -> NSImage {
        if let logo = NSImage(named: NSImage.Name("BrandLogo")) {
            let brandedLogo = (logo.copy() as? NSImage) ?? logo
            brandedLogo.size = NSSize(width: 18, height: 18)
            brandedLogo.isTemplate = false
            return brandedLogo
        }

        return NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "WallSync"
        ) ?? NSImage()
    }
}
