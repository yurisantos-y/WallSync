import XCTest
@testable import WallSync

final class PlaylistTimerPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func session(_ mode: RenderSession.EnergyMode) -> RenderSession {
        RenderSession(
            id: UUID(), displayTarget: Fixture.display(), assetID: UUID(), windowState: .visible,
            playbackState: .animating, energyMode: mode, startedAt: now, lastVisibilityChange: now
        )
    }

    func testNoTimerWithoutATimeDrivenPlaylist() {
        XCTAssertNil(PlaylistTimerPolicy.schedule(nextChange: nil, desktopIsVisible: true, now: now))
    }

    func testNoTimerWhileNobodyCanSeeTheDesktop() {
        XCTAssertNil(PlaylistTimerPolicy.schedule(nextChange: now.addingTimeInterval(60), desktopIsVisible: false, now: now))
    }

    func testOneTimerForTheNextChangeWithTolerance() {
        let next = now.addingTimeInterval(1800)
        let schedule = PlaylistTimerPolicy.schedule(nextChange: next, desktopIsVisible: true, now: now)
        XCTAssertEqual(schedule?.fireDate, next)
        XCTAssertEqual(schedule?.tolerance, 60, "a tenth of the wait, at most a minute")
        XCTAssertEqual(PlaylistTimerPolicy.schedule(nextChange: now.addingTimeInterval(60), desktopIsVisible: true, now: now)?.tolerance, 6)
        XCTAssertEqual(PlaylistTimerPolicy.schedule(nextChange: now.addingTimeInterval(-5), desktopIsVisible: true, now: now)?.tolerance, 1, "overdue fires at once")
    }

    func testDesktopVisibilityInEveryCombination() {
        var state = AppRuntimeState.initial
        XCTAssertTrue(PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: []))
        XCTAssertTrue(PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: [session(.suspend), session(.animate)]))
        XCTAssertTrue(PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: [session(.poster)]), "a still frame is still seen")
        XCTAssertFalse(PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: [session(.suspend), session(.suspend)]), "covered or fullscreen everywhere")

        let invisible: [(inout AppRuntimeState) -> Void] = [
            { $0.isScreenLocked = true }, { $0.displaysAsleep = true }, { $0.isScreenSaverActive = true },
            { $0.sleepState = .sleeping }, { $0.isSessionInactive = true }
        ]
        for configure in invisible {
            state = .initial
            configure(&state)
            XCTAssertFalse(PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: [session(.animate)]))
            XCTAssertNil(
                PlaylistTimerPolicy.schedule(
                    nextChange: now.addingTimeInterval(10),
                    desktopIsVisible: PlaylistTimerPolicy.desktopIsVisible(runtimeState: state, sessions: [session(.animate)]),
                    now: now
                )
            )
        }
    }

    /// Sleep, relaunch, clock set forward or back: the item only depends on
    /// the instant it is asked for.
    func testItemIsCorrectAfterSleepRestartAndClockChanges() throws {
        let assets = (0..<4).map { _ in Fixture.asset() }
        let playlist = WallpaperPlaylist(
            id: UUID(), name: "p", kind: .interval, assetIDs: assets.map(\.id), intervalSeconds: 900, anchor: now
        )
        let usable = Set(assets.map(\.id))
        func item(_ offset: TimeInterval, _ list: WallpaperPlaylist) -> UUID? {
            PlaylistSchedule.activeItem(of: list, context: .init(now: now.addingTimeInterval(offset), usableAssetIDs: usable))
        }

        // "Restart": the playlist goes through storage and back.
        let restored = try JSONDecoder().decode(WallpaperPlaylist.self, from: JSONEncoder().encode(playlist))
        XCTAssertEqual(restored, playlist)

        let offsets: [TimeInterval] = [0, 899, 900, 18_017, 259_242, -30, -86_400]
        for offset in offsets {
            let expected = assets[((Int((offset / 900).rounded(.down)) % 4) + 4) % 4].id
            XCTAssertEqual(item(offset, playlist), expected, "offset \(offset)")
            XCTAssertEqual(item(offset, restored), expected, "after a restart, offset \(offset)")
        }

        var shuffled = playlist
        shuffled.isShuffled = true
        let shuffledRestored = try JSONDecoder().decode(WallpaperPlaylist.self, from: JSONEncoder().encode(shuffled))
        let later: [TimeInterval] = [0, 12_345, 987_654]
        for offset in later {
            XCTAssertEqual(item(offset, shuffled), item(offset, shuffledRestored), "the recorded seed gives the same order after a restart")
        }
    }
}

final class PlaylistStorageTests: XCTestCase {
    func testPlaylistsRoundTripThroughTheStore() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageLocations(root: root)
        let suite = "WallSyncTests-\(UUID().uuidString)"
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!, placementsURL: storage.placementsFile, playlistsURL: storage.playlistsFile)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let missing = await store.loadPlaylists()
        XCTAssertEqual(missing.value, [], "no file yet: no playlists, no error")
        XCTAssertNil(missing.issue)

        let playlists = [
            WallpaperPlaylist(id: UUID(), name: "Day", kind: .timeOfDay, slots: [.init(startMinute: 360, assetID: UUID())]),
            WallpaperPlaylist(id: UUID(), name: "Mix", kind: .interval, assetIDs: [UUID(), UUID()], isShuffled: true, manualOffset: 3)
        ]
        try await store.savePlaylists(playlists)
        let loaded = await store.loadPlaylists()
        XCTAssertEqual(loaded.value, playlists)
    }

    func testRemovingAnAssetCleansEveryKindOfPlaylist() {
        let asset = UUID(), other = UUID()
        var interval = WallpaperPlaylist(id: UUID(), name: "i", kind: .interval, assetIDs: [asset, other, asset])
        var day = WallpaperPlaylist(id: UUID(), name: "d", kind: .timeOfDay, slots: [.init(startMinute: 0, assetID: asset)])
        var appearance = WallpaperPlaylist(id: UUID(), name: "a", kind: .appearance, lightAssetID: asset, darkAssetID: other)
        interval.removeAsset(asset)
        day.removeAsset(asset)
        appearance.removeAsset(asset)
        XCTAssertEqual(interval.assetIDs, [other])
        XCTAssertNil(day.slots[0].assetID)
        XCTAssertEqual(appearance.referencedAssetIDs, [other])
    }
}

@MainActor
final class WallpaperChangeTests: XCTestCase {
    private var environment: FakeEnvironment!
    private var manager: WallpaperSessionManager!

    override func setUp() async throws {
        environment = FakeEnvironment()
        manager = WallpaperSessionManager(
            environment: environment, permissionStore: FakePermissionStore(), energyPolicy: EnergyPolicyController(), sleep: { _ in }
        )
    }

    private var stillImage: CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    func testVisibleChangeDissolvesFromTheCurrentFrame() async {
        let display = Fixture.display()
        let first = Fixture.asset(), second = Fixture.asset()
        environment.snapshotImage = stillImage

        await manager.reconcile(Fixture.request(displays: [display], assets: [first]))
        let oldSurface = environment.surfaces[0]
        let oldEngine = environment.engines[0]
        environment.events = []

        await manager.reconcile(Fixture.request(displays: [display], assets: [second]))

        let newSurface = environment.surfaces[1]
        XCTAssertEqual(oldEngine.snapshotCount, 1, "the frame on screen is captured once")
        XCTAssertEqual(newSurface.transitionImages.count, 1, "the new window starts by showing it")
        XCTAssertEqual(newSurface.fadeDurations, [WallpaperSessionManager.wallpaperChangeFadeDuration])
        XCTAssertTrue(oldSurface.isClosed)
        XCTAssertFalse(oldEngine.isLoaded)
        XCTAssertEqual(oldEngine.attachedCount, 0)
        XCTAssertEqual(environment.events, ["teardown", "prepare"], "the outgoing decoder is released before the incoming one starts")
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [second.id])
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .animating)
    }

    func testReduceMotionSwitchesWithoutADissolve() async {
        let display = Fixture.display()
        environment.snapshotImage = stillImage
        await manager.reconcile(Fixture.request(displays: [display], assets: [Fixture.asset()]))
        await manager.reconcile(Fixture.request(displays: [display], assets: [Fixture.asset()]) { $0.reduceMotionEnabled = true })
        XCTAssertEqual(environment.surfaces[1].fadeDurations, [0])
    }

    func testNothingIsCapturedForADesktopNobodySees() async {
        let display = Fixture.display()
        environment.snapshotImage = stillImage
        await manager.reconcile(Fixture.request(displays: [display], assets: [Fixture.asset()]))
        let oldEngine = environment.engines[0]

        // Locked: the change is a plain replacement with no frame decoded
        // for it and no player prepared.
        await manager.reconcile(Fixture.request(displays: [display], assets: [Fixture.asset()]) { $0.isScreenLocked = true })

        XCTAssertEqual(oldEngine.snapshotCount, 0)
        XCTAssertTrue(environment.surfaces[1].transitionImages.isEmpty)
        XCTAssertTrue(environment.surfaces[1].fadeDurations.isEmpty)
        XCTAssertEqual(environment.engines.count, 2)
        XCTAssertEqual(environment.engines[1].prepareAttempts.count, 0, "nothing is prepared while the screen is locked")
        XCTAssertFalse(environment.engines[1].isPlaying)
    }

    func testHeldPlaylistNeverReachesTheSessionManagerWhileInvisible() async {
        // The full path of criterion 4: resolver output with held items
        // feeds the reconcile; the display keeps its wallpaper and decodes
        // nothing while the screen is locked, however late the playlist is.
        let display = Fixture.display()
        let one = Fixture.asset(), two = Fixture.asset()
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let list = WallpaperPlaylist(id: UUID(), name: "p", kind: .interval, assetIDs: [one.id, two.id], intervalSeconds: 600, anchor: anchor)
        let saved = [WallpaperPlacement(assetID: one.id, scope: .allDisplays, playlistID: list.id)]

        func placements(at offset: TimeInterval, held: [UUID: UUID]?) -> WallpaperResolver.Output {
            WallpaperResolver.resolve(
                .init(displays: [display], placements: saved, playlists: [list], assets: [one, two],
                      now: anchor.addingTimeInterval(offset), heldPlaylistItems: held)
            )
        }

        let visible = placements(at: 10, held: nil)
        await manager.reconcile(Fixture.request(displays: [display], assets: [one, two], placements: visible.placements))
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [one.id])

        // Locked for an hour; the playlist is six changes late.
        let locked = placements(at: 3610, held: visible.playlistItems)
        await manager.reconcile(Fixture.request(displays: [display], assets: [one, two], placements: locked.placements) { $0.isScreenLocked = true })
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [one.id], "no change while locked")
        XCTAssertEqual(environment.engines.count, 1, "no second player was even created")
        XCTAssertFalse(environment.engines[0].isPlaying, "and nothing is decoded")
        XCTAssertNil(PlaylistTimerPolicy.schedule(nextChange: locked.nextChange, desktopIsVisible: false, now: anchor.addingTimeInterval(3610)))

        // Unlocked at 3700 s: step 6, an even step, is the first item
        // again; at 4300 s it is the second.
        let back = placements(at: 4300, held: nil)
        await manager.reconcile(Fixture.request(displays: [display], assets: [one, two], placements: back.placements))
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [two.id], "the item that is right for the current time")
    }
}

@MainActor
final class TransitionLayerTests: XCTestCase {
    func testTransitionLayerExistsOnlyDuringAChange() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        let baseline = view.rootSublayerCount
        XCTAssertFalse(view.hasTransitionImage)

        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        view.setTransitionImage(context.makeImage())
        XCTAssertTrue(view.hasTransitionImage)
        XCTAssertEqual(view.rootSublayerCount, baseline + 1)

        view.fadeOutTransitionImage(duration: 0)
        XCTAssertFalse(view.hasTransitionImage)
        XCTAssertEqual(view.rootSublayerCount, baseline, "gone as soon as the change is over")

        view.setTransitionImage(nil)
        view.fadeOutTransitionImage(duration: 0.5)
        XCTAssertEqual(view.rootSublayerCount, baseline, "no change in progress: nothing to do")
    }

    func testTransitionImageStaysBelowTheDimmingLayer() {
        let view = WallpaperHostView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.setDimming(DimOverlay(opacity: 0.5, color: .black))
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        view.setTransitionImage(context.makeImage())
        XCTAssertEqual(view.layer?.sublayers?.last?.opacity, 0.5, "old and new wallpaper are dimmed alike")
    }
}
