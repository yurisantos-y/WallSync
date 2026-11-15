import AppKit
import XCTest
@testable import WallSync

final class RecentWallpapersTests: XCTestCase {
    private func asset(used: TimeInterval?, imported: TimeInterval, name: String) -> WallpaperAsset {
        var asset = Fixture.asset()
        asset.displayName = name
        asset.lastUsedAt = used.map { Date(timeIntervalSinceReferenceDate: $0) }
        asset.importedAt = Date(timeIntervalSinceReferenceDate: imported)
        return asset
    }

    func testMostRecentlyUsedFirstThenNewestImports() {
        let assets = [
            asset(used: nil, imported: 10, name: "old import"),
            asset(used: 100, imported: 1, name: "used earlier"),
            asset(used: nil, imported: 20, name: "new import"),
            asset(used: 200, imported: 2, name: "used last")
        ]
        let items = RecentWallpapers.items(assets: assets, activeAssetIDs: [assets[1].id])
        XCTAssertEqual(items.map(\.name), ["used last", "used earlier", "new import", "old import"])
        XCTAssertEqual(items.map(\.isActive), [false, true, false, false])
    }

    func testListIsLimitedAndSkipsUnplayableVideos() {
        var assets = (0..<10).map { asset(used: Double($0), imported: 0, name: "w\($0)") }
        assets[9].optimizedPlayback = nil
        assets[9].eligibility = PlaybackProfile(tier: .unsupported, hardwareDecodeLikely: false, reasonCodes: [], isHeavy: true, recommendedMode: .unsupported)

        let items = RecentWallpapers.items(assets: assets, activeAssetIDs: [])
        XCTAssertEqual(items.count, RecentWallpapers.defaultLimit)
        XCTAssertEqual(items.first?.name, "w8", "the unplayable one is not offered")
        XCTAssertTrue(RecentWallpapers.items(assets: [], activeAssetIDs: []).isEmpty)
    }
}

@MainActor
final class StatusMenuTests: XCTestCase {
    private func content(displays: Int, playlist: String? = nil) -> StatusItemController.MenuContent {
        var content = StatusItemController.MenuContent()
        content.recents = [
            .init(assetID: UUID(), name: "Waves", isActive: true, thumbnailURL: nil),
            .init(assetID: UUID(), name: "Forest", isActive: false, thumbnailURL: nil)
        ]
        content.displays = (0..<displays).map { ("d\($0)", "Display \($0)") }
        content.playlistName = playlist
        content.canAdvancePlaylist = playlist != nil
        return content
    }

    func testItemsExistOnlyWhileTheMenuIsOpen() {
        let controller = StatusItemController()
        controller.menuContentProvider = { self.content(displays: 1) }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "fixed", action: nil, keyEquivalent: ""))

        XCTAssertEqual(controller.dynamicItemCount, 0, "nothing is built before the menu opens")
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title).filter { ["Waves", "Forest"].contains($0) }, ["Waves", "Forest"])
        XCTAssertEqual(menu.item(withTitle: "Waves")?.state, .on, "the wallpaper in use is marked")
        XCTAssertEqual(menu.item(withTitle: "Forest")?.state, .off)
        XCTAssertNil(menu.item(withTitle: "Waves")?.submenu, "one display needs no submenu")

        controller.menuDidClose(menu)
        XCTAssertEqual(controller.dynamicItemCount, 0)
        XCTAssertEqual(menu.items.map(\.title), ["fixed"], "nothing stays loaded with the menu closed")
    }

    func testSeveralDisplaysOfferASubmenuAndRouteTheChoice() throws {
        let controller = StatusItemController()
        let content = content(displays: 2, playlist: "Evening")
        controller.menuContentProvider = { content }
        var applied: [(UUID, String?)] = []
        controller.onApplyWallpaper = { applied.append(($0, $1)) }
        var advanced = 0
        controller.onNextWallpaper = { advanced += 1 }

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let forest = try XCTUnwrap(menu.item(withTitle: "Forest"))
        let submenu = try XCTUnwrap(forest.submenu)
        XCTAssertEqual(submenu.items.filter { !$0.isSeparatorItem }.count, 3, "all displays, then one entry per display")

        _ = forest.target?.perform(forest.action, with: forest)
        let second = try XCTUnwrap(submenu.item(withTitle: "Display 1"))
        _ = second.target?.perform(second.action, with: second)

        XCTAssertEqual(applied.map(\.0), [content.recents[1].assetID, content.recents[1].assetID])
        XCTAssertEqual(applied.map(\.1), [nil, "d1"])

        let next = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "n" })
        XCTAssertTrue(next.isEnabled)
        _ = next.target?.perform(next.action)
        XCTAssertEqual(advanced, 1)
        XCTAssertTrue(menu.items.contains { $0.title.contains("Evening") })

        // Reopening rebuilds from scratch instead of accumulating.
        let count = menu.numberOfItems
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.numberOfItems, count)
    }
}
