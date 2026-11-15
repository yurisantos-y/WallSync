import XCTest
@testable import WallSync

final class StartupRestoreGateTests: XCTestCase {
    func testSystemEventsCannotStartWallpapersWhenLaunchRestoreIsOff() {
        var gate = StartupRestoreGate()

        // A display event wins the debounce race against the launch trigger.
        XCTAssertFalse(gate.shouldReconcile(isUserInitiated: false, startOnLaunch: false))
        XCTAssertFalse(gate.shouldReconcile(isUserInitiated: false, startOnLaunch: false))
        // Even if the preference flips later, only a user action lifts it.
        XCTAssertFalse(gate.shouldReconcile(isUserInitiated: false, startOnLaunch: true))

        XCTAssertTrue(gate.shouldReconcile(isUserInitiated: true, startOnLaunch: false))
        XCTAssertTrue(gate.shouldReconcile(isUserInitiated: false, startOnLaunch: false))
    }

    func testLaunchRestoreRunsWhenPreferenceIsOn() {
        var gate = StartupRestoreGate()
        XCTAssertTrue(gate.shouldReconcile(isUserInitiated: false, startOnLaunch: true))
        XCTAssertEqual(gate.phase, .open)
    }
}

final class ContainerFormatDetectorTests: XCTestCase {
    private func header(_ box: String, brand: String) -> Data {
        Data([0, 0, 0, 0x20]) + box.data(using: .ascii)! + brand.data(using: .ascii)!
    }

    func testDetectsContainerFromBytesNotExtension() {
        XCTAssertEqual(ContainerFormatDetector.containerType(header: header("ftyp", brand: "qt  "), fallbackExtension: "mp4"), "mov")
        XCTAssertEqual(ContainerFormatDetector.containerType(header: header("ftyp", brand: "M4V "), fallbackExtension: "m4v"), "mp4")
        XCTAssertEqual(ContainerFormatDetector.containerType(header: header("ftyp", brand: "isom"), fallbackExtension: "bin"), "mp4")
        XCTAssertEqual(ContainerFormatDetector.containerType(header: header("moov", brand: "xxxx"), fallbackExtension: "dat"), "mov")
    }

    func testFallsBackToExtensionForUnknownData() {
        XCTAssertEqual(ContainerFormatDetector.containerType(header: Data([1, 2, 3]), fallbackExtension: "MKV"), "mkv")
        XCTAssertEqual(ContainerFormatDetector.containerType(header: header("RIFF", brand: "AVI "), fallbackExtension: "avi"), "avi")
    }
}

final class EffectiveEligibilityTests: XCTestCase {
    private let evaluator = PlaybackEligibilityEvaluator()

    func testOptimizedRenditionMakesUnsupportedSourcePlayable() {
        let proRes = evaluator.profile(
            containerType: "mov", codecType: "ProRes", pixelSize: CGSize(width: 5120, height: 2880),
            frameRate: 120, estimatedBitRate: 400_000_000, hardwareDecodeLikely: false
        )
        XCTAssertEqual(proRes.tier, .unsupported)

        XCTAssertEqual(evaluator.effectiveProfile(for: Fixture.asset(optimized: false, eligibility: proRes)).tier, .unsupported)
        XCTAssertEqual(evaluator.effectiveProfile(for: Fixture.asset(optimized: true, eligibility: proRes)).tier, .safe)
    }

    func testM4VContainerIsSupported() {
        let profile = evaluator.profile(
            containerType: "m4v", codecType: "H264", pixelSize: CGSize(width: 1920, height: 1080),
            frameRate: 30, estimatedBitRate: 6_000_000, hardwareDecodeLikely: true
        )
        XCTAssertEqual(profile.tier, .safe)
    }

    func testVisibleReasonCodesDoNotMentionMVP() {
        let profile = evaluator.profile(
            containerType: "mp4", codecType: "HEVC", pixelSize: CGSize(width: 7680, height: 4320),
            frameRate: 30, estimatedBitRate: 1, hardwareDecodeLikely: true
        )
        XCTAssertEqual(profile.tier, .unsupported)
        XCTAssertFalse(profile.reasonCodes.contains { $0.contains("mvp") })
    }
}

final class StorageTests: XCTestCase {
    private var root: URL!
    private var storage: StorageLocations!

    override func setUpWithError() throws {
        root = try Fixture.temporaryDirectory()
        storage = StorageLocations(root: root)
        try storage.prepareDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relativePath: String, bytes: Int = 16) throws {
        try Data(count: bytes).write(to: storage.url(forRelativePath: relativePath))
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: storage.url(forRelativePath: relativePath).path)
    }

    func testCorruptedCatalogIsPreservedAndReset() async throws {
        try Data("{ this is not json".utf8).write(to: storage.assetsFile)
        let store = AssetCatalogStore(fileURL: storage.assetsFile)

        let result = await store.loadAssets()

        XCTAssertTrue(result.value.isEmpty)
        guard case let .corruptedFile(name, preservedAs)? = result.issue else {
            return XCTFail("expected a corruption issue")
        }
        XCTAssertEqual(name, "assets.json")
        let preserved = try XCTUnwrap(preservedAs)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(preserved)), "{ this is not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.assetsFile.path))

        // The app keeps working: the next save and load round-trip.
        try await store.saveAssets([Fixture.asset()])
        let reloaded = await store.loadAssets()
        XCTAssertEqual(reloaded.value.count, 1)
        XCTAssertNil(reloaded.issue)
    }

    func testMissingFilesLoadDefaultsWithoutIssue() async {
        let assets = await AssetCatalogStore(fileURL: storage.assetsFile).loadAssets()
        XCTAssertTrue(assets.value.isEmpty)
        XCTAssertNil(assets.issue)

        let defaults = UserDefaults(suiteName: "WallSyncTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults, placementsURL: storage.placementsFile)
        let placements = await settings.loadPlacements()
        let preferences = await settings.loadPreferences()
        XCTAssertTrue(placements.value.isEmpty)
        XCTAssertEqual(preferences.value, .defaultValue)
        XCTAssertNil(preferences.issue)
    }

    func testCorruptedPreferencesFallBackToDefaults() async {
        let suite = "WallSyncTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)!.set(Data("garbage".utf8), forKey: "wallpaper.preferences")

        let result = await SettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            placementsURL: storage.placementsFile
        ).loadPreferences()

        XCTAssertEqual(result.value, .defaultValue)
        XCTAssertNotNil(result.issue)
        XCTAssertEqual(
            UserDefaults(suiteName: suite)!.data(forKey: "wallpaper.preferences.corrupt"),
            Data("garbage".utf8)
        )
    }

    func testRemovingAssetDeletesEverythingItOwns() async throws {
        let asset = Fixture.asset(posterPath: "Posters/poster.png")
        let other = Fixture.asset(posterPath: "Posters/other.png")
        for item in [asset, other] {
            try touch(item.optimizedPlayback!.relativePath)
            try touch(item.posterImageRelativePath!)
        }

        await AssetStorageJanitor(storage: storage).removeFiles(ownedBy: asset)

        XCTAssertFalse(exists(asset.optimizedPlayback!.relativePath))
        XCTAssertFalse(exists(asset.posterImageRelativePath!))
        XCTAssertTrue(exists(other.optimizedPlayback!.relativePath))
        XCTAssertTrue(exists(other.posterImageRelativePath!))
    }

    func testOrphanSweepRemovesOnlyUnreferencedMedia() async throws {
        let kept = Fixture.asset(posterPath: "Posters/kept.png")
        try touch(kept.optimizedPlayback!.relativePath)
        try touch(kept.posterImageRelativePath!)
        try touch("OptimizedVideos/leaked.mp4", bytes: 1000)
        try touch("Posters/leaked.png", bytes: 500)
        try touch("assets.json")

        let reclaimed = await AssetStorageJanitor(storage: storage).removeOrphans(keeping: [kept])

        XCTAssertEqual(reclaimed, 1500)
        XCTAssertFalse(exists("OptimizedVideos/leaked.mp4"))
        XCTAssertFalse(exists("Posters/leaked.png"))
        XCTAssertTrue(exists(kept.optimizedPlayback!.relativePath))
        XCTAssertTrue(exists(kept.posterImageRelativePath!))
        XCTAssertTrue(exists("assets.json"), "files outside the media directories are never touched")
    }

    func testOrphanPolicyIsPure() {
        let asset = Fixture.asset(posterPath: "Posters/a.png")
        let referenced = OrphanCleanupPolicy.referencedRelativePaths(for: [asset])
        XCTAssertEqual(referenced, [asset.optimizedPlayback!.relativePath, "Posters/a.png"])
        XCTAssertEqual(
            OrphanCleanupPolicy.orphans(existingRelativePaths: ["Posters/a.png", "Posters/b.png"], referenced: referenced),
            ["Posters/b.png"]
        )
    }

    func testSecurityScopeCountingStaysBalanced() async throws {
        let file = root.appendingPathComponent("video.mov")
        try Data(count: 8).write(to: file)
        let store = FilePermissionStore(fileURL: storage.bookmarksFile)

        let bookmark: AccessBookmark
        do {
            bookmark = try await store.createBookmark(for: file)
        } catch {
            throw XCTSkip("security-scoped bookmarks are unavailable in this environment: \(error)")
        }
        try await store.storeBookmark(bookmark)

        _ = try await store.resolveBookmark(id: bookmark.id)
        _ = try await store.resolveBookmark(id: bookmark.id)
        var active = await store.activeScopeCount
        XCTAssertEqual(active, 2)

        await store.stopAccess(for: bookmark.id)
        await store.stopAccess(for: bookmark.id)
        await store.stopAccess(for: bookmark.id) // an extra stop is harmless
        active = await store.activeScopeCount
        XCTAssertEqual(active, 0)

        // Bookmarks persist across store instances and are pruned with their asset.
        let reopened = FilePermissionStore(fileURL: storage.bookmarksFile)
        let stored = await reopened.bookmark(for: bookmark.id)
        XCTAssertNotNil(stored)
        let pruned = try await reopened.pruneBookmarks(keeping: [])
        XCTAssertEqual(pruned, 1)
        let afterPrune = await FilePermissionStore(fileURL: storage.bookmarksFile).bookmark(for: bookmark.id)
        XCTAssertNil(afterPrune)
    }

    func testResolvingUnknownBookmarkThrowsWithoutHoldingScope() async {
        let store = FilePermissionStore(fileURL: storage.bookmarksFile)
        do {
            _ = try await store.resolveBookmark(id: UUID())
            XCTFail("expected an error")
        } catch {
            let active = await store.activeScopeCount
            XCTAssertEqual(active, 0)
        }
    }
}

final class DiagnosticsSummaryTests: XCTestCase {
    func testSummaryListsEveryDisplayWithModeReasonAndStream() {
        let displays = [Fixture.display("a", id: 1), Fixture.display("b", id: 2, isPrimary: false)]
        var state = AppRuntimeState.initial
        state.activeDisplays = displays
        state.powerSource = .battery

        var session = RenderSession(
            id: UUID(), displayTarget: displays[0], assetID: UUID(), windowState: .suspended,
            playbackState: .paused, energyMode: .suspend, startedAt: .now, lastVisibilityChange: .now
        )
        session.modeReason = .occluded
        session.playbackSource = .optimized
        session.videoPixelSize = CGSize(width: 3840, height: 2160)
        session.videoFrameRate = 30
        session.videoCodec = "HEVC"

        let text = DiagnosticsSummary.text(
            appVersion: "1.2 (3)", runtimeState: state, preferences: .defaultValue, sessions: [session], assets: []
        )

        XCTAssertTrue(text.contains("WallSync 1.2 (3)"))
        XCTAssertTrue(text.contains("power=battery"))
        XCTAssertTrue(text.contains("energy=suspend reason=occluded playback=paused window=suspended source=optimized"))
        XCTAssertTrue(text.contains("video: 3840x2160 30 fps HEVC"))
        XCTAssertTrue(text.contains("[Display b]"))
        XCTAssertTrue(text.contains("no session"))
        XCTAssertFalse(text.contains("/tmp/"), "file paths never appear in the report")
    }
}

final class LocalizationTests: XCTestCase {
    private func catalog() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Wallpaper/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: [String: Any]])
    }

    private func values(of entry: [String: Any], language: String) -> [String] {
        guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else { return [] }
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]
        return plural.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    func testEveryStringHasEnglishAndBrazilianPortuguese() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 100)
        for (key, entry) in strings {
            XCTAssertFalse(values(of: entry, language: "en").isEmpty, "missing English: \(key)")
            XCTAssertFalse(values(of: entry, language: "pt-BR").isEmpty, "missing Portuguese: \(key)")
        }
    }

    func testPortugueseIsAccentedAndNeverMentionsMVP() throws {
        let portuguese = try catalog().values.flatMap { values(of: $0, language: "pt-BR") }
        let unaccented = ["Nao ", " nao ", "cao ", "coes ", "video", "Inicializacao", "sessao", "Preferencias", "ocluido"]
        for text in portuguese {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("MVP"), text)
            for fragment in unaccented {
                XCTAssertFalse((text + " ").contains(fragment), "unaccented “\(fragment)” in: \(text)")
            }
        }
    }

    func testFormatSpecifiersMatchBetweenLanguages() throws {
        func specifiers(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|@)")
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range(at: 1)) }.sorted()
        }
        for (key, entry) in try catalog() {
            for text in values(of: entry, language: "pt-BR") {
                XCTAssertEqual(specifiers(text), specifiers(key), "specifier mismatch for: \(key)")
            }
        }
    }
}

final class StatusSummaryTests: XCTestCase {
    private func session(_ mode: RenderSession.EnergyMode, _ state: RenderSession.PlaybackState, _ reason: SessionModeReason = .none) -> RenderSession {
        var session = RenderSession(
            id: UUID(), displayTarget: Fixture.display(), assetID: UUID(), windowState: .visible,
            playbackState: state, energyMode: mode, startedAt: .now, lastVisibilityChange: .now
        )
        session.modeReason = reason
        return session
    }

    func testSummaries() {
        XCTAssertEqual(StatusSummary.make(sessions: [], isUserPaused: false), .noWallpapers)
        XCTAssertEqual(StatusSummary.make(sessions: [session(.poster, .poster, .userPaused)], isUserPaused: true), .pausedByUser)
        XCTAssertEqual(
            StatusSummary.make(sessions: [session(.animate, .animating), session(.suspend, .paused, .occluded)], isUserPaused: false),
            .animating(count: 1, total: 2)
        )
        XCTAssertEqual(
            StatusSummary.make(
                sessions: [session(.suspend, .paused, .screenLocked), session(.suspend, .paused, .screenLocked), session(.poster, .poster, .battery)],
                isUserPaused: false
            ),
            .idle(reason: .screenLocked)
        )
    }
}
