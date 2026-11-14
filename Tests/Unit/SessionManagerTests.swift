import XCTest
@testable import WallSync

@MainActor
final class SessionManagerTests: XCTestCase {
    private var environment: FakeEnvironment!
    private var permissions: FakePermissionStore!
    private var manager: WallpaperSessionManager!

    override func setUp() async throws {
        environment = FakeEnvironment()
        permissions = FakePermissionStore()
        manager = WallpaperSessionManager(
            environment: environment,
            permissionStore: permissions,
            energyPolicy: EnergyPolicyController(),
            sleep: { _ in }
        )
    }

    /// Nothing may outlive the sessions that own it.
    private func assertNoLeaks(expectedSessions: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.currentSessions.count, expectedSessions, "sessions", file: file, line: line)
        XCTAssertEqual(environment.openSurfaces.count, expectedSessions, "open windows", file: file, line: line)
        XCTAssertLessThanOrEqual(environment.loadedEngines.count, expectedSessions, "loaded players", file: file, line: line)
        let originals = environment.loadedEngines.filter { $0.preparedURL?.path.hasPrefix("/original/") == true }.count
        let scopes = await permissions.activeScopes
        XCTAssertEqual(scopes, originals, "security scopes", file: file, line: line)
    }

    func testReconcileStartsPlaybackOnEveryDisplay() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset()

        await manager.reconcile(Fixture.request(displays: displays, assets: [asset]))

        XCTAssertEqual(manager.currentSessions.map(\.playbackState), [.animating, .animating])
        XCTAssertTrue(environment.loadedEngines.allSatisfy(\.isPlaying))
        XCTAssertTrue(environment.openSurfaces.allSatisfy { $0.isWindowShown && $0.isShowingVideo })
        await assertNoLeaks(expectedSessions: 2)
    }

    func testConcurrentReconcilesAreCoalescedToTheLatestRequest() async {
        let display = Fixture.display()
        let first = Fixture.asset()
        let second = Fixture.asset()
        let third = Fixture.asset()
        environment.prepareGate = AsyncGate()

        manager.submit(Fixture.request(displays: [display], assets: [first]))
        await environment.prepareGate.waitUntilEntered()

        // Three more requests arrive while the first reconcile is suspended.
        manager.submit(Fixture.request(displays: [display], assets: [second]))
        manager.submit(Fixture.request(displays: [display], assets: [second]))
        manager.submit(Fixture.request(displays: [display], assets: [third]))

        environment.prepareGate.open()
        await manager.waitUntilIdle()

        XCTAssertEqual(manager.appliedReconcileCount, 2, "only the latest pending request is applied")
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [third.id])
        XCTAssertFalse(
            environment.engines.contains { $0.prepareAttempts.contains(FakeEnvironment.optimizedURL(for: second)) },
            "the superseded request must never be prepared"
        )
        await assertNoLeaks(expectedSessions: 1)
    }

    func testOcclusionDuringPreparationSuspendsPlayback() async {
        let display = Fixture.display()
        let asset = Fixture.asset()
        environment.prepareGate = AsyncGate()

        manager.submit(Fixture.request(displays: [display], assets: [asset]))
        await environment.prepareGate.waitUntilEntered()

        environment.surface(for: "display-1")?.simulateOcclusion(true)
        environment.prepareGate.open()
        await manager.waitUntilIdle()

        XCTAssertEqual(manager.currentSessions.first?.energyMode, .suspend)
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .paused)
        XCTAssertFalse(environment.loadedEngines.contains(where: \.isPlaying))

        environment.surface(for: "display-1")?.simulateOcclusion(false)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .animating)
        await assertNoLeaks(expectedSessions: 1)
    }

    func testStopDuringReconcileLeavesNothingBehind() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset(optimized: false)
        environment.prepareGate = AsyncGate()

        manager.submit(Fixture.request(displays: displays, assets: [asset]))
        await environment.prepareGate.waitUntilEntered()

        let stopping = Task { [manager] in await manager?.stopAll() }
        await Task.yield()
        environment.prepareGate.open()
        await stopping.value

        XCTAssertTrue(environment.engines.allSatisfy { !$0.isLoaded })
        await assertNoLeaks(expectedSessions: 0)

        // A system event after the stop must not resurrect the sessions.
        environment.surfaces.first?.simulateOcclusion(false)
        await assertNoLeaks(expectedSessions: 0)
    }

    func testRequestSubmittedAfterStopWins() async {
        let display = Fixture.display()
        let asset = Fixture.asset()

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))
        let stopping = Task { [manager] in await manager?.stopAll() }
        await Task.yield()
        manager.submit(Fixture.request(displays: [display], assets: [asset]))
        await stopping.value

        await assertNoLeaks(expectedSessions: 1)
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .animating)
    }

    func testChangingAssetDuringPlaybackReplacesWindowAndPlayer() async {
        let display = Fixture.display()
        let first = Fixture.asset()
        let second = Fixture.asset()

        await manager.reconcile(Fixture.request(displays: [display], assets: [first]))
        let firstEngine = environment.engines[0]
        let firstSurface = environment.surfaces[0]

        await manager.reconcile(Fixture.request(displays: [display], assets: [second]))

        XCTAssertTrue(firstSurface.isClosed)
        XCTAssertFalse(firstEngine.isLoaded)
        XCTAssertEqual(firstEngine.attachedCount, 0)
        XCTAssertEqual(manager.currentSessions.map(\.assetID), [second.id])
        await assertNoLeaks(expectedSessions: 1)
    }

    func testRemovingDisplayTearsItsSessionDown() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        let asset = Fixture.asset(optimized: false)

        await manager.reconcile(Fixture.request(displays: displays, assets: [asset]))
        await assertNoLeaks(expectedSessions: 2)

        await manager.reconcile(Fixture.request(displays: [displays[0]], assets: [asset]))

        XCTAssertEqual(manager.currentSessions.map(\.displayTarget.displayUUID), ["a"])
        await assertNoLeaks(expectedSessions: 1)

        await manager.reconcile(Fixture.request(displays: [], assets: [asset]))
        await assertNoLeaks(expectedSessions: 0)
    }

    func testFailingOptimizedRenditionFallsBackToOriginal() async {
        let display = Fixture.display()
        let asset = Fixture.asset()
        environment.failingURLs = [FakeEnvironment.optimizedURL(for: asset)]

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))

        let session = manager.currentSessions.first
        XCTAssertEqual(session?.playbackState, .animating)
        XCTAssertEqual(session?.playbackSource, .original)
        XCTAssertEqual(
            environment.engines[0].prepareAttempts,
            [FakeEnvironment.optimizedURL(for: asset), FakePermissionStore.originalURL(for: asset.originalBookmarkID)]
        )
        // The original is decoded at no more than the display's pixel size.
        XCTAssertEqual(environment.engines[0].maximumPixelSizes.last ?? nil, CGSize(width: 3840, height: 2160))
        await assertNoLeaks(expectedSessions: 1)

        await manager.stopAll()
        let scopes = await permissions.activeScopes
        XCTAssertEqual(scopes, 0)
    }

    func testSecurityScopeIsReleasedWhenEverySourceFails() async {
        let display = Fixture.display()
        let asset = Fixture.asset()
        environment.failingURLs = [
            FakeEnvironment.optimizedURL(for: asset),
            FakePermissionStore.originalURL(for: asset.originalBookmarkID)
        ]

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))

        XCTAssertEqual(manager.currentSessions.first?.playbackState, .failed)
        let resolved = await permissions.resolveCount
        let stopped = await permissions.stopCount
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(stopped, 1)

        // Re-evaluations must not hammer a source that is known to fail.
        environment.surfaces.first?.simulateOcclusion(false)
        await manager.waitUntilIdle()
        XCTAssertEqual(environment.engines[0].prepareAttempts.count, 2)
        await assertNoLeaks(expectedSessions: 1)
    }

    func testMissingBookmarkDoesNotLeakScope() async {
        let display = Fixture.display()
        let asset = Fixture.asset(optimized: false)
        await permissions.setFailResolve(true)

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))

        XCTAssertEqual(manager.currentSessions.first?.playbackState, .failed)
        let scopes = await permissions.activeScopes
        XCTAssertEqual(scopes, 0)
    }

    func testIdlePlaybackIsUnloadedAfterGracePeriodAndResumesWhereItStopped() async {
        let display = Fixture.display()
        let asset = Fixture.asset(optimized: false)

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))
        environment.engines[0].currentTime = 4.5

        // Critical thermal pressure: poster mode, then unload (the injected
        // sleep returns immediately, so the grace period elapses at once).
        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]) { $0.thermalState = .critical })
        await Task.yield()
        await manager.waitUntilIdle()
        await manager.waitUntilIdle()

        XCTAssertFalse(environment.engines[0].isLoaded)
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .poster)
        XCTAssertFalse(environment.surfaces[0].isShowingVideo)
        let scopes = await permissions.activeScopes
        XCTAssertEqual(scopes, 0, "the scope is released together with the player")

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))
        XCTAssertEqual(environment.engines[0].startTimes.last, 4.5)
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .animating)
        await assertNoLeaks(expectedSessions: 1)
    }

    func testUnsupportedAssetWithoutRenditionGetsNoSession() async {
        let display = Fixture.display()
        let unsupported = PlaybackProfile(
            tier: .unsupported, hardwareDecodeLikely: false, reasonCodes: ["unsupported_format"],
            isHeavy: true, recommendedMode: .unsupported
        )

        await manager.reconcile(
            Fixture.request(displays: [display], assets: [Fixture.asset(optimized: false, eligibility: unsupported)])
        )
        await assertNoLeaks(expectedSessions: 0)

        // The same source becomes playable once an optimized rendition exists.
        await manager.reconcile(
            Fixture.request(displays: [display], assets: [Fixture.asset(optimized: true, eligibility: unsupported)])
        )
        XCTAssertEqual(manager.currentSessions.first?.playbackState, .animating)
        await assertNoLeaks(expectedSessions: 1)
    }

    func testWindowListIsCapturedOncePerReconcile() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]

        await manager.reconcile(Fixture.request(displays: displays, assets: [Fixture.asset()]))

        XCTAssertEqual(environment.windowSnapshotCaptureCount, manager.appliedReconcileCount)
    }

    func testCoveredDisplayIsSuspendedFromSharedSnapshot() async {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        environment.windowSnapshot = WindowListSnapshot(
            windows: [WindowInfo(ownerPID: 4242, layer: 0, alpha: 1, bounds: displays[1].frame)]
        )
        var fullscreen: Set<String> = []
        manager.onFullscreenDisplaysChanged = { fullscreen = $0 }

        await manager.reconcile(Fixture.request(displays: displays, assets: [Fixture.asset()]))

        let byDisplay = Dictionary(uniqueKeysWithValues: manager.currentSessions.map { ($0.displayTarget.displayUUID, $0) })
        XCTAssertEqual(byDisplay["a"]?.energyMode, .animate)
        XCTAssertEqual(byDisplay["b"]?.energyMode, .suspend)
        XCTAssertEqual(byDisplay["b"]?.windowState, .hidden)
        XCTAssertEqual(fullscreen, ["b"])
    }
}
