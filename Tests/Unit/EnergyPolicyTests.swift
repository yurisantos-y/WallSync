import XCTest
@testable import WallSync

final class EnergyPolicyTests: XCTestCase {
    private let policy = EnergyPolicyController()

    private func context(_ configure: (inout SystemContext) -> Void = { _ in }) -> SystemContext {
        var context = SystemContext(
            onBattery: false, lowPowerMode: false, thermalState: .nominal, isOccluded: false,
            isFullscreen: false, assetIsHeavy: false, isPrimaryDisplay: true, activeDisplayCount: 1
        )
        configure(&context)
        return context
    }

    private var permissivePreferences: UserPreferences {
        var preferences = UserPreferences.defaultValue
        preferences.pauseWhenOccluded = false
        preferences.pauseWhenFullscreen = false
        preferences.reduceOnBattery = false
        return preferences
    }

    func testVisibleDesktopAnimates() {
        XCTAssertEqual(policy.decision(for: context(), preferences: .defaultValue), SessionModeDecision(mode: .animate, reason: .none))
    }

    func testInvisibleStatesSuspendEvenWhenEveryPreferenceIsOff() {
        let cases: [(SessionModeReason, (inout SystemContext) -> Void)] = [
            (.systemSleeping, { $0.isSystemSleeping = true }),
            (.screenLocked, { $0.isScreenLocked = true }),
            (.displaysAsleep, { $0.displaysAsleep = true }),
            (.screenSaver, { $0.isScreenSaverActive = true }),
            (.sessionInactive, { $0.isSessionInactive = true })
        ]

        for (reason, configure) in cases {
            XCTAssertEqual(
                policy.decision(for: context(configure), preferences: permissivePreferences),
                SessionModeDecision(mode: .suspend, reason: reason)
            )
        }
    }

    func testOcclusionAndFullscreenRemainPreferences() {
        XCTAssertEqual(policy.mode(for: context { $0.isOccluded = true }, preferences: permissivePreferences), .animate)
        XCTAssertEqual(policy.mode(for: context { $0.isFullscreen = true }, preferences: permissivePreferences), .animate)
        XCTAssertEqual(
            policy.decision(for: context { $0.isOccluded = true }, preferences: .defaultValue),
            SessionModeDecision(mode: .suspend, reason: .occluded)
        )
    }

    func testLockTakesPrecedenceOverEverythingElse() {
        let decision = policy.decision(
            for: context {
                $0.isScreenLocked = true
                $0.isUserPaused = true
                $0.isFullscreen = true
                $0.thermalState = .critical
            },
            preferences: .defaultValue
        )
        XCTAssertEqual(decision, SessionModeDecision(mode: .suspend, reason: .screenLocked))
    }

    func testUserPauseShowsStillFrame() {
        XCTAssertEqual(
            policy.decision(for: context { $0.isUserPaused = true }, preferences: .defaultValue),
            SessionModeDecision(mode: .poster, reason: .userPaused)
        )
    }

    func testReduceMotionIsOptIn() {
        var preferences = UserPreferences.defaultValue
        XCTAssertEqual(policy.mode(for: context { $0.reduceMotionEnabled = true }, preferences: preferences), .animate)

        preferences.pauseWhenReduceMotion = true
        XCTAssertEqual(
            policy.decision(for: context { $0.reduceMotionEnabled = true }, preferences: preferences),
            SessionModeDecision(mode: .poster, reason: .reduceMotion)
        )
        XCTAssertEqual(policy.mode(for: context(), preferences: preferences), .animate)
    }

    func testInvisibleOnBatteryReleasesPlayerAfterGracePeriod() {
        let locked = context {
            $0.isScreenLocked = true
            $0.onBattery = true
        }
        XCTAssertEqual(policy.playbackUnloadGracePeriod(for: .suspend, context: locked, preferences: .defaultValue), .seconds(30))

        let lockedOnAC = context { $0.isScreenLocked = true }
        XCTAssertNil(policy.playbackUnloadGracePeriod(for: .suspend, context: lockedOnAC, preferences: .defaultValue))
    }

    func testSixtyFramesPerSecondIsStillTreatedAsHeavy() {
        let profile = PlaybackEligibilityEvaluator().profile(
            containerType: "mp4", codecType: "HEVC", pixelSize: CGSize(width: 1920, height: 1080),
            frameRate: 60, estimatedBitRate: 8_000_000, hardwareDecodeLikely: true
        )
        XCTAssertTrue(profile.isHeavy)
        XCTAssertEqual(
            policy.decision(
                for: context {
                    $0.onBattery = true
                    $0.assetIsHeavy = profile.isHeavy
                },
                preferences: .defaultValue
            ),
            SessionModeDecision(mode: .poster, reason: .battery)
        )
    }
}

final class OcclusionPollingPolicyTests: XCTestCase {
    private func session(_ mode: RenderSession.EnergyMode, _ reason: SessionModeReason) -> RenderSession {
        var session = RenderSession(
            id: UUID(), displayTarget: Fixture.display(), assetID: UUID(), windowState: .visible,
            playbackState: .idle, energyMode: mode, startedAt: .now, lastVisibilityChange: .now
        )
        session.modeReason = reason
        return session
    }

    func testPollsWhileSomethingIsAnimating() {
        XCTAssertTrue(OcclusionPollingPolicy.shouldPoll(sessions: [session(.suspend, .screenLocked), session(.animate, .none)]))
    }

    func testPollsWhileCoverageIsTheOnlyThingHoldingPlayback() {
        XCTAssertTrue(OcclusionPollingPolicy.shouldPoll(sessions: [session(.suspend, .occluded)]))
        XCTAssertTrue(OcclusionPollingPolicy.shouldPoll(sessions: [session(.suspend, .fullscreen)]))
    }

    func testStaysIdleWhenEveryHoldHasItsOwnNotification() {
        XCTAssertFalse(OcclusionPollingPolicy.shouldPoll(sessions: []))
        XCTAssertFalse(
            OcclusionPollingPolicy.shouldPoll(sessions: [
                session(.suspend, .screenLocked),
                session(.suspend, .displaysAsleep),
                session(.suspend, .systemSleeping),
                session(.suspend, .sessionInactive),
                session(.suspend, .screenSaver),
                session(.poster, .userPaused),
                session(.poster, .battery),
                session(.poster, .thermalPressure),
                session(.poster, .reduceMotion)
            ])
        )
    }
}

final class PreferencesCompatibilityTests: XCTestCase {
    func testPreferencesSavedByPreviousVersionStillDecode() throws {
        let legacy = """
        {"launchAtLogin":true,"startOnLaunch":false,"reduceOnBattery":false,
         "pauseWhenFullscreen":true,"pauseWhenOccluded":false,"fallbackMode":"batterySaver"}
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(UserPreferences.self, from: legacy)

        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertFalse(preferences.startOnLaunch)
        XCTAssertFalse(preferences.reduceOnBattery)
        XCTAssertFalse(preferences.pauseWhenOccluded)
        XCTAssertEqual(preferences.fallbackMode, .batterySaver)
        // Fields added later take their defaults.
        XCTAssertEqual(preferences.playbackQuality, .efficiency)
        XCTAssertFalse(preferences.pauseWhenReduceMotion)
    }

    func testUnknownEnumValuesFallBackInsteadOfFailing() throws {
        let future = #"{"fallbackMode":"turbo","playbackQuality":"cinematic"}"#.data(using: .utf8)!
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: future)
        XCTAssertEqual(preferences.fallbackMode, .balanced)
        XCTAssertEqual(preferences.playbackQuality, .efficiency)
        XCTAssertTrue(preferences.startOnLaunch)
    }

    func testPreferencesRoundTrip() throws {
        var preferences = UserPreferences.defaultValue
        preferences.playbackQuality = .smooth
        preferences.pauseWhenReduceMotion = true
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
    }
}
