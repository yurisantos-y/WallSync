import XCTest
@testable import WallSync

final class IntentRequestValidatorTests: XCTestCase {
    private let display = Fixture.display("a", id: 1)

    private func validate(
        _ request: WallpaperActionRequest,
        assets: [WallpaperAsset] = [],
        playlists: [WallpaperPlaylist] = [],
        advanceable: Set<UUID> = []
    ) -> WallpaperActionError? {
        do {
            try IntentRequestValidator.validate(
                request, assets: assets, playlists: playlists, displays: [display], advanceablePlaylistIDs: advanceable
            )
            return nil
        } catch {
            return error as? WallpaperActionError
        }
    }

    func testSetWallpaper() {
        let asset = Fixture.asset()
        XCTAssertNil(validate(.setWallpaper(assetID: asset.id, displayUUID: nil), assets: [asset]))
        XCTAssertNil(validate(.setWallpaper(assetID: asset.id, displayUUID: "a"), assets: [asset]))
        XCTAssertEqual(validate(.setWallpaper(assetID: UUID(), displayUUID: nil), assets: [asset]), .wallpaperNotFound, "removed from the library")
        XCTAssertEqual(validate(.setWallpaper(assetID: asset.id, displayUUID: "gone"), assets: [asset]), .displayNotConnected)

        var unplayable = Fixture.asset(optimized: false)
        unplayable.eligibility = PlaybackProfile(tier: .unsupported, hardwareDecodeLikely: false, reasonCodes: [], isHeavy: true, recommendedMode: .unsupported)
        XCTAssertEqual(validate(.setWallpaper(assetID: unplayable.id, displayUUID: nil), assets: [unplayable]), .wallpaperNotPlayable)
    }

    func testActivatePlaylist() {
        let asset = Fixture.asset()
        let playlist = WallpaperPlaylist(id: UUID(), name: "p", assetIDs: [asset.id])
        let empty = WallpaperPlaylist(id: UUID(), name: "e", assetIDs: [UUID()])

        XCTAssertNil(validate(.activatePlaylist(playlistID: playlist.id, displayUUID: nil), assets: [asset], playlists: [playlist]))
        XCTAssertEqual(validate(.activatePlaylist(playlistID: UUID(), displayUUID: nil), assets: [asset], playlists: [playlist]), .playlistNotFound)
        XCTAssertEqual(validate(.activatePlaylist(playlistID: empty.id, displayUUID: nil), assets: [asset], playlists: [empty]), .playlistEmpty, "its wallpapers were all removed")
        XCTAssertEqual(validate(.activatePlaylist(playlistID: playlist.id, displayUUID: "gone"), assets: [asset], playlists: [playlist]), .displayNotConnected)
    }

    func testNextWallpaperNeedsAPlaylistInRotation() {
        XCTAssertEqual(validate(.nextWallpaper), .noPlaylistInRotation)
        XCTAssertNil(validate(.nextWallpaper, advanceable: [UUID()]))
    }

    func testEveryErrorHasAMessage() {
        let errors: [WallpaperIntentError] = [
            .appNotReady, .action(.wallpaperNotFound), .action(.wallpaperNotPlayable), .action(.playlistNotFound),
            .action(.playlistEmpty), .action(.displayNotConnected), .action(.noPlaylistInRotation)
        ]
        let messages = Set(errors.map { String(localized: $0.localizedStringResource) })
        XCTAssertEqual(messages.count, errors.count, "each error says something different")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }
}

final class FocusFilterTests: XCTestCase {
    func testBehaviorMapsToTheTemporaryOverride() {
        let wallpaper = UUID(), playlist = UUID()
        XCTAssertNil(FocusFilterBehavior.noChange.override(wallpaperID: wallpaper, playlistID: playlist), "also what the system sends when the Focus ends")
        XCTAssertEqual(FocusFilterBehavior.pause.override(wallpaperID: nil, playlistID: nil), .pause)
        XCTAssertEqual(FocusFilterBehavior.wallpaper.override(wallpaperID: wallpaper, playlistID: playlist), .asset(wallpaper))
        XCTAssertEqual(FocusFilterBehavior.playlist.override(wallpaperID: wallpaper, playlistID: playlist), .playlist(playlist))
        XCTAssertNil(FocusFilterBehavior.wallpaper.override(wallpaperID: nil, playlistID: playlist), "nothing chosen: nothing overridden")
        XCTAssertNil(FocusFilterBehavior.playlist.override(wallpaperID: wallpaper, playlistID: nil))
    }

    func testIntentEnumCoversEveryBehavior() {
        for behavior in FocusFilterBehavior.allCases {
            XCTAssertEqual(FocusWallpaperBehavior(rawValue: behavior.rawValue)?.behavior, behavior)
        }
        XCTAssertEqual(FocusWallpaperBehavior.caseDisplayRepresentations.count, FocusFilterBehavior.allCases.count)
    }

    /// Criterion 9, end to end through the resolver and the session
    /// manager: a Focus comes and goes, the earlier state is back, and the
    /// saved assignments were never written to.
    @MainActor
    func testFocusEndingRestoresThePreviousStateAndLeavesAssignmentsAlone() async {
        let environment = FakeEnvironment()
        let manager = WallpaperSessionManager(
            environment: environment, permissionStore: FakePermissionStore(), energyPolicy: EnergyPolicyController(), sleep: { _ in }
        )
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let global = Fixture.asset(), own = Fixture.asset(), focusAsset = Fixture.asset()
        let assets = [global, own, focusAsset]
        let saved = [
            WallpaperPlacement(assetID: global.id, scope: .allDisplays),
            WallpaperPlacement(assetID: own.id, scope: .specificDisplay("b"), contentMode: .aspectFit)
        ]
        let savedCopy = saved

        func reconcile(focus: FocusOverride?) async {
            let output = WallpaperResolver.resolve(.init(displays: displays, placements: saved, assets: assets, focus: focus))
            await manager.reconcile(
                Fixture.request(displays: displays, assets: assets, placements: output.placements) { $0.isFocusPaused = output.pause == .focus }
            )
        }
        func shown() -> [String: UUID] {
            Dictionary(uniqueKeysWithValues: manager.currentSessions.map { ($0.displayTarget.displayUUID, $0.assetID) })
        }

        await reconcile(focus: nil)
        let before = shown()
        XCTAssertEqual(before, ["a": global.id, "b": own.id])

        await reconcile(focus: .asset(focusAsset.id))
        XCTAssertEqual(shown(), ["a": focusAsset.id, "b": focusAsset.id])

        await reconcile(focus: nil)
        XCTAssertEqual(shown(), before, "the Focus ended: the previous wallpapers are back")
        XCTAssertEqual(environment.surface(for: "b")?.contentMode, .aspectFit)

        await reconcile(focus: .pause)
        XCTAssertEqual(shown(), before, "pausing keeps the wallpapers")
        XCTAssertTrue(manager.currentSessions.allSatisfy { $0.modeReason == .focusFilter && $0.energyMode == .poster })
        XCTAssertTrue(environment.loadedEngines.allSatisfy { !$0.isPlaying }, "nothing is decoded while the Focus pauses")

        await reconcile(focus: nil)
        XCTAssertTrue(manager.currentSessions.allSatisfy { $0.playbackState == .animating })
        XCTAssertEqual(saved, savedCopy, "the saved assignments were never changed")
    }
}
