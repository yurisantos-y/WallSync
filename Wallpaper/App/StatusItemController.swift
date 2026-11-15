import AppKit
import Foundation
import ImageIO

/// Menu bar item: quick pause / resume, a one-line status, the most recently
/// used wallpapers and the usual entries.
///
/// The list of wallpapers is built when the menu opens and thrown away when
/// it closes: with the menu closed the controller holds no thumbnails and
/// does no work.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Status {
        var isPaused: Bool
        var summary: String
        var hasWallpapers: Bool
    }

    struct RecentEntry {
        var assetID: UUID
        var name: String
        var isActive: Bool
        /// The small library thumbnail, never the full-resolution poster.
        var thumbnailURL: URL?
    }

    /// Everything only needed while the menu is open.
    struct MenuContent {
        var recents: [RecentEntry] = []
        var displays: [(uuid: String, name: String)] = []
        /// Name of the playlist in rotation, when there is one.
        var playlistName: String?
        var canAdvancePlaylist = false
    }

    var onOpenSettings: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onQuit: (() -> Void)?
    var statusProvider: (() -> Status)?
    var menuContentProvider: (() -> MenuContent)?
    /// A wallpaper was chosen; a `nil` display means every display.
    var onApplyWallpaper: ((UUID, String?) -> Void)?
    var onNextWallpaper: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")
    /// Items that exist only while the menu is open.
    private var dynamicItems: [NSMenuItem] = []
    /// Invalidates thumbnail loads that finish after the menu closed.
    private var menuGeneration = 0

    private static let thumbnailPointSize = NSSize(width: 36, height: 20)

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
        rebuildDynamicItems(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        removeDynamicItems(from: menu)
    }

    /// Updates the fixed items and the icon from the current state.
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

    // MARK: - Recent wallpapers

    /// Number of items that only exist while the menu is open; used by tests.
    var dynamicItemCount: Int { dynamicItems.count }

    func rebuildDynamicItems(in menu: NSMenu) {
        removeDynamicItems(from: menu)
        guard let content = menuContentProvider?() else { return }

        var items: [NSMenuItem] = []

        if let playlistName = content.playlistName {
            let header = NSMenuItem(title: String(localized: "Playlist: \(playlistName)"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)

            let next = NSMenuItem(title: String(localized: "Next wallpaper"), action: #selector(nextWallpaper), keyEquivalent: "n")
            next.target = self
            next.isEnabled = content.canAdvancePlaylist
            items.append(next)
            items.append(.separator())
        }

        if !content.recents.isEmpty {
            let header = NSMenuItem(title: String(localized: "Recent wallpapers"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)

            for entry in content.recents {
                let item = NSMenuItem(title: entry.name, action: #selector(applyWallpaper(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Selection(assetID: entry.assetID, displayUUID: nil)
                item.state = entry.isActive ? .on : .off
                item.image = Self.placeholderThumbnail
                item.setAccessibilityLabel(
                    entry.isActive ? String(localized: "\(entry.name), in use") : entry.name
                )

                if content.displays.count > 1 {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    let all = NSMenuItem(title: String(localized: "All displays"), action: #selector(applyWallpaper(_:)), keyEquivalent: "")
                    all.target = self
                    all.representedObject = Selection(assetID: entry.assetID, displayUUID: nil)
                    submenu.addItem(all)
                    submenu.addItem(.separator())
                    for display in content.displays {
                        let displayItem = NSMenuItem(title: display.name, action: #selector(applyWallpaper(_:)), keyEquivalent: "")
                        displayItem.target = self
                        displayItem.representedObject = Selection(assetID: entry.assetID, displayUUID: display.uuid)
                        submenu.addItem(displayItem)
                    }
                    item.submenu = submenu
                }

                items.append(item)
                loadThumbnail(entry.thumbnailURL, into: item)
            }
            items.append(.separator())
        }

        // Between the pause item's separator and "Open WallSync…".
        var index = min(menu.index(of: pauseItem) + 2, menu.numberOfItems)
        for item in items {
            menu.insertItem(item, at: index)
            index += 1
        }
        dynamicItems = items
    }

    private func removeDynamicItems(from menu: NSMenu) {
        menuGeneration += 1
        for item in dynamicItems {
            item.image = nil
            if menu.index(of: item) >= 0 {
                menu.removeItem(item)
            }
        }
        dynamicItems = []
    }

    private func loadThumbnail(_ url: URL?, into item: NSMenuItem) {
        guard let url else { return }
        let generation = menuGeneration
        let pixelSize = Int(Self.thumbnailPointSize.width * 2)

        Task { [weak self, weak item] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeThumbnail(url: url, maximumPixelDimension: pixelSize)
            }.value
            // The menu closed (or was rebuilt) meanwhile: keep nothing.
            guard let self, let item, let decoded, self.menuGeneration == generation else { return }
            item.image = Self.menuImage(from: decoded.image)
        }
    }

    private nonisolated static func decodeThumbnail(url: URL, maximumPixelDimension: Int) -> CGImageBox? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(CGImageBox.init)
    }

    /// Fits the thumbnail into a fixed box so every row lines up.
    private static func menuImage(from image: CGImage) -> NSImage {
        let box = thumbnailPointSize
        let source = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return NSImage(size: box, flipped: false) { rect in
            let scale = max(rect.width / source.size.width, rect.height / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            source.draw(in: NSRect(origin: origin, size: size))
            return true
        }
    }

    private static var placeholderThumbnail: NSImage {
        NSImage(size: thumbnailPointSize, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    private final class Selection: NSObject {
        let assetID: UUID
        let displayUUID: String?

        init(assetID: UUID, displayUUID: String?) {
            self.assetID = assetID
            self.displayUUID = displayUUID
        }
    }

    // MARK: - Actions

    @objc
    private func applyWallpaper(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? Selection else { return }
        onApplyWallpaper?(selection.assetID, selection.displayUUID)
    }

    @objc
    private func nextWallpaper() {
        onNextWallpaper?()
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
