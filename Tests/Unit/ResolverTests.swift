import XCTest
@testable import WallSync

final class EditRecipeTests: XCTestCase {
    func testEmptyRecipeStaysEmptyAndOldCatalogsDecodeToIt() throws {
        XCTAssertTrue(EditRecipe.empty.isEmpty)
        XCTAssertTrue(EditRecipe.empty.normalized(duration: 10).isEmpty)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .empty)
    }

    func testNormalizationClampsEveryValue() {
        var recipe = EditRecipe()
        recipe.trim = .init(start: -3, end: 40)
        recipe.loopCrossfade = 9
        recipe.watermarkRegions = [CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), CGRect(x: 2, y: 2, width: 1, height: 1)]
        recipe.crop = CGRect(x: 0, y: 0, width: 1, height: 1)

        let normalized = recipe.normalized(duration: 10)
        XCTAssertNil(normalized.trim, "a selection covering the whole video is no trim")
        XCTAssertEqual(normalized.loopCrossfade, 3, "capped at the maximum")
        XCTAssertEqual(normalized.watermarkRegions.count, 1, "regions outside the picture are dropped")
        XCTAssertEqual(normalized.watermarkRegions[0].maxX, 1, accuracy: 1e-9)
        XCTAssertNil(normalized.crop, "a crop that keeps everything is no crop")
    }

    func testCrossfadeNeverConsumesMoreThanHalfTheSelection() {
        var recipe = EditRecipe()
        recipe.trim = .init(start: 2, end: 6)
        recipe.loopCrossfade = 3
        let timing = recipe.timing(duration: 10)
        XCTAssertEqual(timing.crossfade, 2)
        XCTAssertEqual(timing.outputDuration, 2)
        XCTAssertEqual(timing.start, 2)
        XCTAssertEqual(timing.end, 6)
    }

    func testRecipeChangeMakesTheRenditionStale() {
        var asset = Fixture.asset()
        XCTAssertFalse(OptimizationPlanner.isStale(asset: asset))
        asset.editRecipe.loopCrossfade = 1
        XCTAssertTrue(OptimizationPlanner.isStale(asset: asset))
        XCTAssertTrue(OptimizationPlanner.needsReoptimization(asset: asset, maximumPixelSize: CGSize(width: 1920, height: 1080), quality: .efficiency))
        asset.optimizedPlayback?.recipe = asset.editRecipe.normalized(duration: asset.duration)
        XCTAssertFalse(OptimizationPlanner.isStale(asset: asset))
    }

    func testPlannerKeepsPassthroughOnlyForLosslessEdits() {
        let source = SourceVideoDescription(
            codec: "HEVC", pixelSize: CGSize(width: 1920, height: 1080), frameRate: 30, bitRate: 6_000_000,
            bitDepth: 8, isHDR: false, hardwareDecodable: true, hasTransform: false
        )
        let target = OptimizationTarget(maximumPixelSize: CGSize(width: 1920, height: 1080), quality: .efficiency)
        XCTAssertEqual(OptimizationPlanner.plan(source: source, target: target), .passthrough)
        XCTAssertEqual(OptimizationPlanner.plan(source: source, target: target, recipe: .empty), .passthrough, "an empty recipe changes nothing")

        var trimmed = EditRecipe()
        trimmed.trim = .init(start: 2, end: 6)
        XCTAssertEqual(OptimizationPlanner.plan(source: source, target: target, recipe: trimmed, trimIsKeyframeAligned: true), .passthrough)
        XCTAssertNotEqual(OptimizationPlanner.plan(source: source, target: target, recipe: trimmed, trimIsKeyframeAligned: false), .passthrough)

        var crossfaded = trimmed
        crossfaded.loopCrossfade = 1
        XCTAssertNotEqual(OptimizationPlanner.plan(source: source, target: target, recipe: crossfaded, trimIsKeyframeAligned: true), .passthrough)

        var marked = EditRecipe()
        marked.watermarkRegions = [CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1)]
        XCTAssertNotEqual(OptimizationPlanner.plan(source: source, target: target, recipe: marked), .passthrough)

        var cropped = EditRecipe()
        cropped.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        guard case let .transcode(plan) = OptimizationPlanner.plan(source: source, target: target, recipe: cropped) else {
            return XCTFail("a crop needs a re-encode")
        }
        XCTAssertEqual(plan.pixelSize, CGSize(width: 960, height: 540), "the visible part is never enlarged")
    }
}

final class PlaylistScheduleTests: XCTestCase {
    private let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func intervalPlaylist(_ ids: [UUID], shuffled: Bool = false, seed: UInt64 = 42) -> WallpaperPlaylist {
        WallpaperPlaylist(
            id: UUID(), name: "p", kind: .interval, assetIDs: ids, intervalSeconds: 600,
            isShuffled: shuffled, seed: seed, anchor: anchor
        )
    }

    private func context(_ offset: TimeInterval, usable: [UUID], dark: Bool = false) -> PlaylistSchedule.Context {
        PlaylistSchedule.Context(now: anchor.addingTimeInterval(offset), calendar: utc, isDarkAppearance: dark, usableAssetIDs: Set(usable))
    }

    func testIntervalItemIsAFunctionOfTheClock() {
        let ids = (0..<4).map { _ in UUID() }
        let playlist = intervalPlaylist(ids)

        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(0, usable: ids)), ids[0])
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(599, usable: ids)), ids[0])
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(600, usable: ids)), ids[1])
        // Eight hours asleep: no catching up, just the right item.
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(8 * 3600, usable: ids)), ids[(8 * 6) % 4])
        // The clock was set back before the anchor.
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(-1, usable: ids)), ids[3])
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(-601, usable: ids)), ids[2])
    }

    func testNextChangeIsTheNextBoundary() {
        let ids = (0..<3).map { _ in UUID() }
        let playlist = intervalPlaylist(ids)
        XCTAssertEqual(PlaylistSchedule.state(of: playlist, context: context(250, usable: ids)).nextChange, anchor.addingTimeInterval(600))
        XCTAssertEqual(PlaylistSchedule.state(of: playlist, context: context(600, usable: ids)).nextChange, anchor.addingTimeInterval(1200))
        XCTAssertEqual(PlaylistSchedule.state(of: playlist, context: context(-250, usable: ids)).nextChange, anchor)
    }

    func testManualOffsetAdvancesWithoutMovingTheBoundaries() {
        let ids = (0..<3).map { _ in UUID() }
        var playlist = intervalPlaylist(ids)
        playlist.manualOffset = 1
        let state = PlaylistSchedule.state(of: playlist, context: context(250, usable: ids))
        XCTAssertEqual(state.assetID, ids[1])
        XCTAssertEqual(state.nextChange, anchor.addingTimeInterval(600))
    }

    func testItemsStillBeingOptimizedAreSkipped() {
        let ids = (0..<3).map { _ in UUID() }
        let playlist = intervalPlaylist(ids)
        let usable = [ids[0], ids[2]]
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(600, usable: usable)), ids[2])
        XCTAssertNil(PlaylistSchedule.activeItem(of: playlist, context: context(600, usable: [])))

        let single = PlaylistSchedule.state(of: playlist, context: context(600, usable: [ids[1]]))
        XCTAssertEqual(single.assetID, ids[1])
        XCTAssertNil(single.nextChange, "one usable item never changes, so it needs no timer")
    }

    func testShuffleIsDeterministicCoversEveryItemAndNeverRepeatsAcrossPasses() {
        let ids = (0..<5).map { _ in UUID() }
        let playlist = intervalPlaylist(ids, shuffled: true, seed: 7)
        let sequence = (0..<60).map { step in
            PlaylistSchedule.activeItem(of: playlist, context: context(Double(step) * 600 + 1, usable: ids))!
        }
        let again = (0..<60).map { step in
            PlaylistSchedule.activeItem(of: playlist, context: context(Double(step) * 600 + 1, usable: ids))!
        }
        XCTAssertEqual(sequence, again, "same seed, same order")

        for pass in 0..<12 {
            XCTAssertEqual(Set(sequence[(pass * 5)..<(pass * 5 + 5)]).count, 5, "every pass shows every item once")
        }
        for index in 1..<sequence.count {
            XCTAssertNotEqual(sequence[index], sequence[index - 1], "no immediate repeat at step \(index)")
        }

        let other = intervalPlaylist(ids, shuffled: true, seed: 8)
        let otherSequence = (0..<60).map { step in
            PlaylistSchedule.activeItem(of: other, context: context(Double(step) * 600 + 1, usable: ids))!
        }
        XCTAssertNotEqual(sequence, otherSequence)
    }

    func testTimeOfDaySlotsWrapAroundMidnightAndFollowTheTimeZone() {
        let morning = UUID(), afternoon = UUID(), night = UUID()
        let playlist = WallpaperPlaylist(
            id: UUID(), name: "day", kind: .timeOfDay,
            slots: [
                .init(startMinute: 12 * 60, assetID: afternoon),
                .init(startMinute: 6 * 60, assetID: morning),
                .init(startMinute: 19 * 60 + 30, assetID: night)
            ]
        )
        let usable = Set([morning, afternoon, night])
        func date(_ hour: Int, _ minute: Int, zone: String = "UTC") -> (Date, Calendar) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            return (calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!, calendar)
        }
        func state(_ hour: Int, _ minute: Int, zone: String = "UTC") -> PlaylistSchedule.State {
            let (now, calendar) = date(hour, minute, zone: zone)
            return PlaylistSchedule.state(of: playlist, context: .init(now: now, calendar: calendar, usableAssetIDs: usable))
        }

        XCTAssertEqual(state(3, 0).assetID, night, "before the first slot, last night's slot is still on")
        XCTAssertEqual(state(6, 0).assetID, morning)
        XCTAssertEqual(state(11, 59).assetID, morning)
        XCTAssertEqual(state(12, 0).assetID, afternoon)
        XCTAssertEqual(state(19, 30).assetID, night)
        XCTAssertEqual(state(23, 59).assetID, night)

        XCTAssertEqual(state(7, 15).nextChange, date(12, 0).0)
        XCTAssertEqual(state(20, 0).nextChange, date(6, 0).0.addingTimeInterval(24 * 3600))

        // The same instant in another time zone is a different part of the day.
        let (instant, _) = date(7, 0)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(
            PlaylistSchedule.activeItem(of: playlist, context: .init(now: instant, calendar: tokyo, usableAssetIDs: usable)),
            afternoon
        )
    }

    func testAppearancePlaylistFollowsTheSystemAndFallsBack() {
        let light = UUID(), dark = UUID()
        let playlist = WallpaperPlaylist(id: UUID(), name: "a", kind: .appearance, lightAssetID: light, darkAssetID: dark)
        XCTAssertEqual(PlaylistSchedule.state(of: playlist, context: context(0, usable: [light, dark])), .init(assetID: light, nextChange: nil))
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(0, usable: [light, dark], dark: true)), dark)
        XCTAssertEqual(PlaylistSchedule.activeItem(of: playlist, context: context(0, usable: [light], dark: true)), light)
    }

    func testPlaylistDecodesWithMissingFields() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(WallpaperPlaylist.self, from: Data(#"{"id":"\#(id.uuidString)"}"#.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.kind, .interval)
        XCTAssertEqual(decoded.intervalSeconds, 1800)
    }
}

final class WallpaperResolverTests: XCTestCase {
    private let displayA = Fixture.display("a", id: 1)
    private let displayB = Fixture.display("b", id: 2, isPrimary: false)
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func input(
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement],
        playlists: [WallpaperPlaylist] = [],
        focus: FocusOverride? = nil,
        paused: Bool = false,
        offset: TimeInterval = 0,
        held: [UUID: UUID]? = nil
    ) -> WallpaperResolver.Input {
        WallpaperResolver.Input(
            displays: [displayA, displayB], placements: placements, playlists: playlists, assets: assets,
            focus: focus, isUserPaused: paused, now: now.addingTimeInterval(offset), heldPlaylistItems: held
        )
    }

    private func playlist(_ assets: [WallpaperAsset]) -> WallpaperPlaylist {
        WallpaperPlaylist(id: UUID(), name: "p", kind: .interval, assetIDs: assets.map(\.id), intervalSeconds: 600, anchor: now)
    }

    func testFixedAssignmentsResolveLikeTheReconciliationPolicy() {
        let global = Fixture.asset(), own = Fixture.asset()
        let placements = [
            WallpaperPlacement(assetID: global.id, scope: .allDisplays),
            WallpaperPlacement(assetID: own.id, scope: .specificDisplay("b"), contentMode: .aspectFit)
        ]
        let output = WallpaperResolver.resolve(input(assets: [global, own], placements: placements))

        XCTAssertEqual(output.displays.map(\.assetID), [global.id, own.id])
        XCTAssertEqual(output.displays.map(\.source), [.fixed, .fixed])
        XCTAssertNil(output.pause)
        XCTAssertNil(output.nextChange)
        XCTAssertTrue(output.playlistItems.isEmpty)

        // The output drives the existing reconcile to the same sessions.
        let policy = SessionReconciliationPolicy()
        let direct = policy.desiredSessions(displays: [displayA, displayB], assets: [global, own], placements: placements)
        let resolved = policy.desiredSessions(displays: [displayA, displayB], assets: [global, own], placements: output.placements)
        XCTAssertEqual(resolved.map(\.asset.id), direct.map(\.asset.id))
        XCTAssertEqual(resolved.map(\.placement.contentMode), direct.map(\.placement.contentMode))
        XCTAssertEqual(resolved.map(\.placement.id), direct.map(\.placement.id))
    }

    func testPlaylistReplacesTheFixedAssetAndReportsTheNextChange() {
        let fallback = Fixture.asset(), one = Fixture.asset(), two = Fixture.asset()
        let list = playlist([one, two])
        let placements = [WallpaperPlacement(assetID: fallback.id, scope: .allDisplays, playlistID: list.id)]

        let first = WallpaperResolver.resolve(input(assets: [fallback, one, two], placements: placements, playlists: [list]))
        XCTAssertEqual(first.displays.map(\.assetID), [one.id, one.id])
        XCTAssertEqual(first.displays.map(\.source), [.playlist(list.id), .playlist(list.id)])
        XCTAssertEqual(first.playlistItems, [list.id: one.id])
        XCTAssertEqual(first.nextChange, now.addingTimeInterval(600))

        let later = WallpaperResolver.resolve(input(assets: [fallback, one, two], placements: placements, playlists: [list], offset: 601))
        XCTAssertEqual(later.displays.map(\.assetID), [two.id, two.id])
    }

    func testPlaylistWithNothingUsableFallsBackToTheFixedAsset() {
        let fallback = Fixture.asset()
        var pending = Fixture.asset(optimized: false)
        pending.optimizationState = .pending
        let list = playlist([pending])
        let placements = [WallpaperPlacement(assetID: fallback.id, scope: .allDisplays, playlistID: list.id)]

        let output = WallpaperResolver.resolve(input(assets: [fallback, pending], placements: placements, playlists: [list]))
        XCTAssertEqual(output.displays.map(\.assetID), [fallback.id, fallback.id])
        XCTAssertEqual(output.displays.map(\.source), [.fixed, .fixed])
        XCTAssertNil(output.nextChange)

        let missing = WallpaperResolver.resolve(
            input(assets: [fallback], placements: [WallpaperPlacement(assetID: fallback.id, scope: .allDisplays, playlistID: UUID())])
        )
        XCTAssertEqual(missing.displays.map(\.assetID), [fallback.id, fallback.id], "a deleted playlist behaves like no playlist")
    }

    func testHeldItemsDoNotAdvanceWhileTheDesktopIsInvisible() {
        let one = Fixture.asset(), two = Fixture.asset()
        let list = playlist([one, two])
        let placements = [WallpaperPlacement(assetID: one.id, scope: .allDisplays, playlistID: list.id)]

        let held = WallpaperResolver.resolve(
            input(assets: [one, two], placements: placements, playlists: [list], offset: 601, held: [list.id: one.id])
        )
        XCTAssertEqual(held.displays.map(\.assetID), [one.id, one.id], "nothing is switched for a desktop nobody sees")

        let released = WallpaperResolver.resolve(input(assets: [one, two], placements: placements, playlists: [list], offset: 601))
        XCTAssertEqual(released.displays.map(\.assetID), [two.id, two.id], "the right item is computed when the desktop is back")

        let stale = WallpaperResolver.resolve(
            input(assets: [two], placements: [WallpaperPlacement(assetID: two.id, scope: .allDisplays, playlistID: list.id)],
                  playlists: [list], offset: 601, held: [list.id: one.id])
        )
        XCTAssertEqual(stale.displays.map(\.assetID), [two.id, two.id], "a held item that was removed is not kept")
    }

    func testFocusOverridesPlaylistsAndFixedAssetsOnEveryDisplay() {
        let global = Fixture.asset(), own = Fixture.asset(), focus = Fixture.asset(), item = Fixture.asset()
        let list = playlist([item, global])
        let placements = [
            WallpaperPlacement(assetID: global.id, scope: .allDisplays, playlistID: list.id),
            WallpaperPlacement(assetID: own.id, scope: .specificDisplay("b"), contentMode: .aspectFit)
        ]
        let assets = [global, own, focus, item]

        let output = WallpaperResolver.resolve(input(assets: assets, placements: placements, playlists: [list], focus: .asset(focus.id)))
        XCTAssertEqual(output.displays.map(\.assetID), [focus.id, focus.id])
        XCTAssertEqual(output.displays.map(\.source), [.focus, .focus])
        XCTAssertEqual(output.displays.map(\.placement.contentMode), [.aspectFill, .aspectFit], "each display keeps its own scaling")
        XCTAssertNil(output.nextChange, "a playlist hidden behind the Focus asks for no timer")
        XCTAssertNil(output.pause)

        // Focus naming something that no longer exists changes nothing.
        let gone = WallpaperResolver.resolve(input(assets: assets, placements: placements, playlists: [list], focus: .asset(UUID())))
        XCTAssertEqual(gone.displays.map(\.assetID), [item.id, own.id])

        let focusList = playlist([focus, own])
        let viaPlaylist = WallpaperResolver.resolve(
            input(assets: assets, placements: placements, playlists: [list, focusList], focus: .playlist(focusList.id), offset: 601)
        )
        XCTAssertEqual(viaPlaylist.displays.map(\.assetID), [own.id, own.id])
        XCTAssertEqual(viaPlaylist.playlistItems, [focusList.id: own.id])
        XCTAssertEqual(viaPlaylist.nextChange, now.addingTimeInterval(1200))
    }

    func testFocusCanPutAWallpaperOnADisplayThatHasNone() {
        let focus = Fixture.asset()
        let output = WallpaperResolver.resolve(input(assets: [focus], placements: [], focus: .asset(focus.id)))
        XCTAssertEqual(output.displays.map(\.assetID), [focus.id, focus.id])
        XCTAssertTrue(WallpaperResolver.resolve(input(assets: [focus], placements: [])).displays.isEmpty)
    }

    func testPauseSourcesAndTheirPrecedence() {
        let asset = Fixture.asset()
        let placements = [WallpaperPlacement(assetID: asset.id, scope: .allDisplays)]

        XCTAssertEqual(WallpaperResolver.resolve(input(assets: [asset], placements: placements, focus: .pause)).pause, .focus)
        XCTAssertEqual(WallpaperResolver.resolve(input(assets: [asset], placements: placements, paused: true)).pause, .user)
        XCTAssertEqual(
            WallpaperResolver.resolve(input(assets: [asset], placements: placements, focus: .pause, paused: true)).pause, .user,
            "the user's pause outranks the Focus filter"
        )
        // Pausing keeps the content: only the motion stops.
        XCTAssertEqual(
            WallpaperResolver.resolve(input(assets: [asset], placements: placements, focus: .pause, paused: true)).displays.map(\.assetID),
            [asset.id, asset.id]
        )
    }

    /// Every combination of the four layers: the result always follows the
    /// documented precedence, and removing the temporary layers always gives
    /// back exactly what was there before.
    func testExhaustiveLayerCombinations() {
        let fixed = Fixture.asset(), own = Fixture.asset(), listed = Fixture.asset(), second = Fixture.asset(), focusAsset = Fixture.asset()
        let assets = [fixed, own, listed, second, focusAsset]
        let list = playlist([listed, second])
        let focusList = playlist([second, listed])

        let placementVariants: [[WallpaperPlacement]] = [
            [],
            [WallpaperPlacement(assetID: fixed.id, scope: .allDisplays)],
            [WallpaperPlacement(assetID: fixed.id, scope: .allDisplays, playlistID: list.id)],
            [WallpaperPlacement(assetID: fixed.id, scope: .allDisplays), WallpaperPlacement(assetID: own.id, scope: .specificDisplay("b"))],
            [WallpaperPlacement(assetID: fixed.id, scope: .allDisplays, playlistID: list.id), WallpaperPlacement(assetID: own.id, scope: .specificDisplay("b"))],
            [WallpaperPlacement(assetID: own.id, scope: .primaryOnly, playlistID: list.id)]
        ]
        let focusVariants: [FocusOverride?] = [nil, .pause, .asset(focusAsset.id), .playlist(focusList.id), .asset(UUID()), .playlist(UUID())]
        var combinations = 0

        for placements in placementVariants {
            let saved = placements
            let baseline = WallpaperResolver.resolve(input(assets: assets, placements: placements, playlists: [list, focusList]))

            for focus in focusVariants {
                for paused in [false, true] {
                    combinations += 1
                    let output = WallpaperResolver.resolve(
                        input(assets: assets, placements: placements, playlists: [list, focusList], focus: focus, paused: paused)
                    )
                    let label = "placements=\(placements.count) focus=\(String(describing: focus)) paused=\(paused)"

                    // 1. Manual pause.
                    if paused {
                        XCTAssertEqual(output.pause, .user, label)
                    } else {
                        XCTAssertEqual(output.pause, focus == .pause ? .focus : nil, label)
                    }

                    // 2. Focus content, when it names something that exists.
                    let focusItem: UUID?
                    switch focus {
                    case .asset(let id)? where id == focusAsset.id: focusItem = id
                    case .playlist(let id)? where id == focusList.id: focusItem = second.id
                    default: focusItem = nil
                    }

                    if let focusItem {
                        XCTAssertEqual(output.displays.map(\.displayUUID), ["a", "b"], label)
                        XCTAssertTrue(output.displays.allSatisfy { $0.assetID == focusItem && $0.source == .focus }, label)
                    } else {
                        // 3 and 4: exactly the baseline; pause changes no content.
                        XCTAssertEqual(output.displays, baseline.displays, label)
                        XCTAssertEqual(output.nextChange, baseline.nextChange, label)
                    }

                    for content in output.displays {
                        XCTAssertTrue(assets.contains { $0.id == content.assetID }, label)
                        XCTAssertEqual(content.placement.scope, .specificDisplay(content.displayUUID), label)
                        XCTAssertEqual(content.placement.assetID, content.assetID, label)
                    }
                    XCTAssertEqual(placements, saved, "the saved assignments are never written to")
                }
            }

            // Temporary layers gone: the earlier state is back by itself.
            XCTAssertEqual(WallpaperResolver.resolve(input(assets: assets, placements: placements, playlists: [list, focusList])), baseline)
        }
        XCTAssertEqual(combinations, 72)
    }
}

final class PlacementCompatibilityTests: XCTestCase {
    func testPlacementsWrittenBeforePlaylistsAndPanoramasStillLoad() throws {
        let id = UUID(), assetID = UUID()
        let json = """
        [{"id":"\(id.uuidString)","assetID":"\(assetID.uuidString)","scope":{"kind":"allDisplays"},"contentMode":"aspectFit","isEnabled":true}]
        """
        let decoded = try JSONDecoder().decode([WallpaperPlacement].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, id)
        XCTAssertEqual(decoded[0].contentMode, .aspectFit)
        XCTAssertNil(decoded[0].playlistID)
        XCTAssertFalse(decoded[0].spansDisplays)
        XCTAssertEqual(decoded[0].panoramaOffset, .zero)

        let roundTrip = try JSONDecoder().decode([WallpaperPlacement].self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testAssetsWrittenBeforeTheNewFieldsStillLoad() throws {
        let asset = Fixture.asset()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(asset)) as? [String: Any])
        for key in ["editRecipe", "playbackRate", "dimmingOverride", "lastUsedAt"] { object[key] = nil }
        var rendition = try XCTUnwrap(object["optimizedPlayback"] as? [String: Any])
        rendition["recipe"] = nil
        rendition["watermarkStrategies"] = nil
        object["optimizedPlayback"] = rendition

        let decoded = try JSONDecoder().decode(WallpaperAsset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.editRecipe, .empty)
        XCTAssertEqual(decoded.playbackRate, 1)
        XCTAssertNil(decoded.dimmingOverride)
        XCTAssertNil(decoded.lastUsedAt)
        XCTAssertEqual(decoded.optimizedPlayback?.recipe, .empty)
        XCTAssertFalse(OptimizationPlanner.isStale(asset: decoded), "old renditions are not redone")
    }
}
