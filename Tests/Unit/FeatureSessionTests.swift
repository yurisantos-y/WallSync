import XCTest
@testable import WallSync

/// Session-manager behaviour added by the product features.
@MainActor
final class FeatureSessionTests: XCTestCase {
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

    // MARK: - Speed

    func testDefaultSpeedNeverTouchesTheEngine() async {
        await manager.reconcile(Fixture.request(displays: [Fixture.display()], assets: [Fixture.asset()]))
        XCTAssertEqual(environment.engines[0].playbackRates, [], "a feature left at its default costs nothing")
    }

    func testSpeedChangeIsAppliedWithoutReloadingTheVideo() async {
        let display = Fixture.display()
        var asset = Fixture.asset()
        asset.playbackRate = 0.5

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))
        let engine = environment.engines[0]
        XCTAssertEqual(engine.playbackRates, [0.5])

        asset.playbackRate = 0.25
        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))
        await manager.reconcile(Fixture.request(displays: [display], assets: [asset]))

        XCTAssertEqual(engine.playbackRates, [0.5, 0.25], "set once per change, not once per reconcile")
        XCTAssertEqual(engine.prepareAttempts.count, 1, "no new rendition and no reload")
        XCTAssertEqual(engine.teardownCount, 0)
        XCTAssertEqual(environment.surfaces.count, 1)
    }

    func testOutOfRangeSpeedIsClamped() {
        var asset = Fixture.asset()
        asset.playbackRate = 3
        XCTAssertEqual(asset.effectivePlaybackRate, 1)
        asset.playbackRate = 0
        XCTAssertEqual(asset.effectivePlaybackRate, 0.25)
        asset.playbackRate = .nan
        XCTAssertEqual(asset.effectivePlaybackRate, 1)
    }

    // MARK: - Dimming

    func testNoDimmingMeansTheSurfaceIsNeverTouched() async {
        await manager.reconcile(Fixture.request(displays: [Fixture.display()], assets: [Fixture.asset()]))
        XCTAssertEqual(environment.surfaces[0].dimmingHistory.count, 0)
    }

    func testDimmingFollowsPreferencesAssetOverrideAndAppearance() async {
        let display = Fixture.display()
        var asset = Fixture.asset()
        var preferences = UserPreferences.defaultValue
        preferences.dimming.amount = 0.3
        preferences.dimming.dimMoreInDarkMode = true

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset], preferences: preferences))
        let surface = environment.surfaces[0]
        XCTAssertEqual(surface.dimming, DimOverlay(opacity: 0.3, color: .black))

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset], preferences: preferences) { $0.isDarkAppearance = true })
        XCTAssertEqual(surface.dimming?.opacity ?? 0, 0.5, accuracy: 1e-9, "dark appearance adds the extra amount")

        asset.dimmingOverride = 0
        await manager.reconcile(Fixture.request(displays: [display], assets: [asset], preferences: preferences))
        XCTAssertNil(surface.dimming, "an override of zero removes the layer")

        await manager.reconcile(Fixture.request(displays: [display], assets: [asset], preferences: preferences))
        XCTAssertEqual(surface.dimmingHistory.count, 3, "unchanged dimming is not re-applied")
        XCTAssertEqual(environment.engines[0].prepareAttempts.count, 1, "dimming never reloads the video")
    }
}
