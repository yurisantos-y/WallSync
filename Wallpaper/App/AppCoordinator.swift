import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppCoordinator {
    @ObservationIgnored let storage: StorageLocations
    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let assetCatalogStore: AssetCatalogStore
    @ObservationIgnored let permissionStore: FilePermissionStore
    @ObservationIgnored let posterCacheStore: PosterCacheStore
    @ObservationIgnored let metadataLoader: AssetMetadataLoader
    @ObservationIgnored let posterFrameGenerator: PosterFrameGenerator
    @ObservationIgnored let videoAssetOptimizer: VideoAssetOptimizer
    @ObservationIgnored let displayManager: DisplayManager
    @ObservationIgnored let energyPolicy: EnergyPolicyController
    @ObservationIgnored let startupLoginManager: StartupLoginManager
    @ObservationIgnored let nativeDesktopPictureManager: NativeDesktopPictureManager

    @ObservationIgnored private let startupManager: StartupManager
    @ObservationIgnored private let reconciliationPolicy = SessionReconciliationPolicy()
    @ObservationIgnored private let powerSourceMonitor: PowerSourceMonitor
    @ObservationIgnored private let thermalMonitor: ThermalMonitor
    @ObservationIgnored private let importVideoUseCase: ImportVideoUseCase
    @ObservationIgnored private let statusItemController: StatusItemController
    @ObservationIgnored private let systemMonitor: SystemEventMonitor
    @ObservationIgnored private let sessionManager: WallpaperSessionManager
    @ObservationIgnored private let janitor: AssetStorageJanitor
    @ObservationIgnored private var scheduledReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var restoreGate = StartupRestoreGate()
    @ObservationIgnored private var startupIssues: [StorageIssue] = []
    @ObservationIgnored private var hasLoadedPersistedState = false
    @ObservationIgnored private var openMainWindowAction: (() -> Void)?

    var assets: [WallpaperAsset] = []
    var placements: [WallpaperPlacement] = []
    var preferences: UserPreferences = .defaultValue
    var runtimeState: AppRuntimeState = .initial
    var activeSessions: [RenderSession] = []
    var startupLoginState: StartupLoginState = .disabled
    var lastErrorMessage: String?

    init() {
        let storage: StorageLocations
        do {
            storage = try StorageLocations.resolve()
        } catch {
            // Keep the app usable for this run and tell the user why nothing
            // will be saved, instead of crashing at launch.
            let fallback = StorageLocations(
                root: FileManager.default.temporaryDirectory.appendingPathComponent("WallSync-unsaved", isDirectory: true)
            )
            try? fallback.prepareDirectories()
            storage = fallback
            startupIssues.append(.storageUnavailable(description: error.localizedDescription))
        }

        let settingsStore = SettingsStore(placementsURL: storage.placementsFile)
        let assetCatalogStore = AssetCatalogStore(fileURL: storage.assetsFile)
        let permissionStore = FilePermissionStore(fileURL: storage.bookmarksFile)
        let posterCacheStore = PosterCacheStore(storage: storage)
        let metadataLoader = AssetMetadataLoader()
        let posterFrameGenerator = PosterFrameGenerator()
        let videoAssetOptimizer = VideoAssetOptimizer(storage: storage)
        let janitor = AssetStorageJanitor(storage: storage)
        let energyPolicy = EnergyPolicyController()

        self.storage = storage
        self.settingsStore = settingsStore
        self.assetCatalogStore = assetCatalogStore
        self.permissionStore = permissionStore
        self.posterCacheStore = posterCacheStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.videoAssetOptimizer = videoAssetOptimizer
        self.janitor = janitor
        self.displayManager = DisplayManager()
        self.energyPolicy = energyPolicy
        self.startupLoginManager = StartupLoginManager()
        self.nativeDesktopPictureManager = NativeDesktopPictureManager(storage: storage)
        self.startupManager = StartupManager()
        self.powerSourceMonitor = PowerSourceMonitor()
        self.thermalMonitor = ThermalMonitor()
        self.statusItemController = StatusItemController()
        self.systemMonitor = SystemEventMonitor()

        self.importVideoUseCase = ImportVideoUseCase(
            storage: storage,
            permissionStore: permissionStore,
            metadataLoader: metadataLoader,
            posterFrameGenerator: posterFrameGenerator,
            posterCacheStore: posterCacheStore,
            videoAssetOptimizer: videoAssetOptimizer,
            janitor: janitor
        )

        self.sessionManager = WallpaperSessionManager(
            environment: LiveSessionEnvironment(storage: storage, posterCacheStore: posterCacheStore),
            permissionStore: permissionStore,
            energyPolicy: energyPolicy
        )

        self.sessionManager.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.activeSessions = sessions
            self.updateRuntimeState {
                $0.visibleSessions = Set(sessions.filter { $0.windowState == .visible }.map(\.id))
            }
        }

        self.sessionManager.onFullscreenDisplaysChanged = { [weak self] displayUUIDs in
            self?.updateRuntimeState {
                $0.fullscreenDisplayUUIDs = displayUUIDs
            }
        }

        self.systemMonitor.handler = { [weak self] event in
            self?.handleSystemEvent(event)
        }
        self.statusItemController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        self.statusItemController.onQuit = {
            NSApp.terminate(nil)
        }
    }

    func start() {
        statusItemController.start()
        systemMonitor.start()

        Task {
            await loadPersistedState()
            scheduleReconcile(trigger: .appLaunch, reason: "initial_restore")
        }
    }

    /// Returns once every window, player and security scope has been released.
    func shutdown() async {
        scheduledReconcileTask?.cancel()
        systemMonitor.stop()
        await sessionManager.stopAll()
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func openSettings() {
        openMainWindow()
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = applicationWindows().first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        openMainWindowAction?()
    }

    func registerOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func importVideo() {
        Task {
            do {
                guard let asset = try await importVideoUseCase.run() else { return }

                assets.insert(asset, at: 0)
                try await assetCatalogStore.saveAssets(assets)

                if placements.isEmpty {
                    placements = [WallpaperPlacement(assetID: asset.id, scope: .allDisplays)]
                    try await settingsStore.savePlacements(placements)
                    refreshRuntimeState()
                    syncNativeDesktopPictures()
                }

                scheduleReconcile(trigger: .manual, reason: "asset_imported")
            } catch {
                present(error)
            }
        }
    }

    func removeAsset(_ asset: WallpaperAsset) {
        Task {
            updateAssets {
                $0.removeAll { $0.id == asset.id }
            }
            updatePlacements {
                $0.removeAll { $0.assetID == asset.id }
            }

            do {
                try await assetCatalogStore.saveAssets(assets)
                try await settingsStore.savePlacements(placements)
            } catch {
                present(error)
            }

            // Stop anything still playing the asset before its files go away.
            await reconcileNow(reason: "asset_removed")
            await deleteStoredData(of: asset)
        }
    }

    /// Frees everything an asset owns: optimized video, poster, cached poster
    /// and the security-scoped bookmark of the original file.
    private func deleteStoredData(of asset: WallpaperAsset) async {
        await posterCacheStore.evict(relativePath: asset.posterImageRelativePath)
        await janitor.removeFiles(ownedBy: asset)

        let bookmarkStillUsed = assets.contains { $0.originalBookmarkID == asset.originalBookmarkID }
        if !bookmarkStillUsed {
            do {
                try await permissionStore.removeBookmark(id: asset.originalBookmarkID)
            } catch {
                present(error)
            }
        }
    }

    func setGlobalAsset(_ assetID: UUID?) {
        updatePlacements { placements in
            guard let assetID else {
                placements.removeAll {
                    if case .allDisplays = $0.scope {
                        return true
                    }
                    return false
                }
                return
            }

            if let existingIndex = placements.firstIndex(where: {
                if case .allDisplays = $0.scope {
                    return true
                }
                return false
            }) {
                placements[existingIndex].assetID = assetID
            } else {
                placements.append(WallpaperPlacement(assetID: assetID, scope: .allDisplays))
            }
        }

        persistPlacementsAndReconcile(
            reason: assetID == nil ? "global_assignment_cleared" : "global_assignment_changed"
        )
    }

    func assignedAssetID(for display: DisplayTarget) -> UUID? {
        placement(for: display)?.assetID
    }

    func globalAssetID() -> UUID? {
        placements.first {
            if case .allDisplays = $0.scope {
                return true
            }
            return false
        }?.assetID
    }

    func contentMode(for display: DisplayTarget) -> WallpaperPlacement.ContentMode {
        placement(for: display)?.contentMode ?? .aspectFill
    }

    func effectiveAsset(for display: DisplayTarget) -> WallpaperAsset? {
        guard let assetID = assignedAssetID(for: display) else { return nil }
        return assets.first { $0.id == assetID }
    }

    func hasDisplayOverride(for display: DisplayTarget) -> Bool {
        placements.contains {
            if case let .specificDisplay(displayUUID) = $0.scope {
                return displayUUID == display.displayUUID
            }
            return false
        }
    }

    func session(for display: DisplayTarget) -> RenderSession? {
        activeSessions.first { $0.displayTarget.displayUUID == display.displayUUID }
    }

    func isDisplayFullscreen(_ display: DisplayTarget) -> Bool {
        runtimeState.fullscreenDisplayUUIDs.contains(display.displayUUID)
    }

    func posterURL(for asset: WallpaperAsset) -> URL? {
        asset.posterImageRelativePath.map(storage.url(forRelativePath:))
    }

    func assignAsset(_ assetID: UUID?, to display: DisplayTarget) {
        updatePlacements { placements in
            if let existingIndex = placements.firstIndex(where: {
                if case let .specificDisplay(displayUUID) = $0.scope {
                    return displayUUID == display.displayUUID
                }
                return false
            }) {
                if let assetID {
                    placements[existingIndex].assetID = assetID
                } else {
                    placements.remove(at: existingIndex)
                }
            } else if let assetID {
                placements.append(
                    WallpaperPlacement(
                        assetID: assetID,
                        scope: .specificDisplay(display.displayUUID)
                    )
                )
            }
        }

        persistPlacementsAndReconcile(reason: "display_assignment_changed")
    }

    func updateContentMode(_ contentMode: WallpaperPlacement.ContentMode, for display: DisplayTarget) {
        var didUpdate = false

        updatePlacements { placements in
            if let existingIndex = placements.firstIndex(where: {
                if case let .specificDisplay(displayUUID) = $0.scope {
                    return displayUUID == display.displayUUID
                }
                return false
            }) {
                placements[existingIndex].contentMode = contentMode
                didUpdate = true
                return
            }

            guard let assetID = assignedAssetID(for: display) else { return }

            placements.append(
                WallpaperPlacement(
                    assetID: assetID,
                    scope: .specificDisplay(display.displayUUID),
                    contentMode: contentMode
                )
            )
            didUpdate = true
        }

        guard didUpdate else { return }
        persistPlacementsAndReconcile(reason: "content_mode_changed")
    }

    func updateStartOnLaunch(_ enabled: Bool) {
        updatePreferences {
            $0.startOnLaunch = enabled
        }
        persistPreferencesAndReconcile(reason: "start_on_launch_changed")
    }

    func updateReduceOnBattery(_ enabled: Bool) {
        updatePreferences {
            $0.reduceOnBattery = enabled
        }
        persistPreferencesAndReconcile(reason: "reduce_on_battery_changed")
    }

    func updatePauseWhenFullscreen(_ enabled: Bool) {
        updatePreferences {
            $0.pauseWhenFullscreen = enabled
        }
        persistPreferencesAndReconcile(reason: "pause_when_fullscreen_changed")
    }

    func updatePauseWhenOccluded(_ enabled: Bool) {
        updatePreferences {
            $0.pauseWhenOccluded = enabled
        }
        persistPreferencesAndReconcile(reason: "pause_when_occluded_changed")
    }

    func updateFallbackMode(_ mode: UserPreferences.FallbackMode) {
        updatePreferences {
            $0.fallbackMode = mode
        }
        persistPreferencesAndReconcile(reason: "fallback_mode_changed")
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        updatePreferences {
            $0.launchAtLogin = enabled
        }

        Task {
            do {
                try startupLoginManager.setLaunchAtLogin(enabled)
                startupLoginState = startupLoginManager.currentState()
                try await settingsStore.savePreferences(preferences)
            } catch {
                present(error)
            }
        }
    }

    private func loadPersistedState() async {
        let loadedPreferences = await settingsStore.loadPreferences()
        let loadedPlacements = await settingsStore.loadPlacements()
        let loadedAssets = await assetCatalogStore.loadAssets()
        let bookmarkIssue = await permissionStore.load()

        preferences = loadedPreferences.value
        placements = loadedPlacements.value
        assets = loadedAssets.value
        startupLoginState = startupLoginManager.currentState()
        hasLoadedPersistedState = true
        refreshRuntimeState()

        startupIssues.append(
            contentsOf: [loadedPreferences.issue, loadedPlacements.issue, loadedAssets.issue, bookmarkIssue].compactMap { $0 }
        )
        if !startupIssues.isEmpty {
            lastErrorMessage = startupIssues.map(\.message).joined(separator: "\n")
        }

        // Never sweep "orphans" against a catalog that failed to load: every
        // file would look unreferenced.
        if loadedAssets.issue == nil && startupIssues.allSatisfy({ if case .storageUnavailable = $0 { return false } else { return true } }) {
            await janitor.removeOrphans(keeping: assets)
            if bookmarkIssue == nil {
                _ = try? await permissionStore.pruneBookmarks(keeping: Set(assets.map(\.originalBookmarkID)))
            }
        }
    }

    private func refreshRuntimeState() {
        let activeDisplays = displayManager.currentDisplays()
        updateRuntimeState {
            $0.activeDisplays = activeDisplays
            $0.powerSource = powerSourceMonitor.currentPowerSource()
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.thermalState = thermalMonitor.currentThermalState()
        }
    }

    private func refreshEnvironmentAndReconcile(reason: String) async {
        guard runtimeState.sleepState == .awake else { return }

        refreshRuntimeState()
        syncNativeDesktopPictures()

        await sessionManager.reconcile(
            SessionReconcileRequest(
                displays: runtimeState.activeDisplays,
                assets: assets,
                placements: placements,
                preferences: preferences,
                runtimeState: runtimeState
            )
        )
    }

    /// Reconciles immediately, bypassing the debounce, and waits for it.
    private func reconcileNow(reason: String) async {
        scheduledReconcileTask?.cancel()
        guard restoreGate.shouldReconcile(isUserInitiated: true, startOnLaunch: preferences.startOnLaunch) else { return }
        await refreshEnvironmentAndReconcile(reason: reason)
    }

    private func persistPreferencesAndReconcile(reason: String) {
        Task {
            do {
                try await settingsStore.savePreferences(preferences)
                scheduleReconcile(trigger: .manual, reason: reason)
            } catch {
                present(error)
            }
        }
    }

    private func persistPlacementsAndReconcile(reason: String) {
        Task {
            do {
                try await settingsStore.savePlacements(placements)
                refreshRuntimeState()
                syncNativeDesktopPictures()
                scheduleReconcile(trigger: .manual, reason: reason)
            } catch {
                present(error)
            }
        }
    }

    private func placement(for display: DisplayTarget) -> WallpaperPlacement? {
        reconciliationPolicy.resolvedPlacement(
            for: display,
            placements: placements
        )
    }

    private func handleSystemEvent(_ event: SystemEventMonitor.Event) {
        switch event {
        case .willSleep:
            scheduledReconcileTask?.cancel()
            updateRuntimeState {
                $0.sleepState = .sleeping
            }
            Task {
                await sessionManager.stopAll()
            }
        case .didWake:
            updateRuntimeState {
                $0.sleepState = .awake
            }
            scheduleReconcile(trigger: .wake, reason: "wake_restore")
        case .displaysChanged:
            scheduleReconcile(trigger: .displayChange, reason: "display_changed")
        case .activeSpaceChanged:
            scheduleReconcile(trigger: .activeSpaceChange, reason: "space_changed")
        case .powerStateChanged:
            scheduleReconcile(trigger: .powerChange, reason: "power_changed")
        case .thermalStateChanged:
            scheduleReconcile(trigger: .thermalChange, reason: "thermal_changed")
        }
    }

    private func present(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    private func updateAssets(_ mutate: (inout [WallpaperAsset]) -> Void) {
        var updated = assets
        mutate(&updated)
        assets = updated
    }

    private func updatePlacements(_ mutate: (inout [WallpaperPlacement]) -> Void) {
        var updated = placements
        mutate(&updated)
        placements = updated
    }

    private func updatePreferences(_ mutate: (inout UserPreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        preferences = updated
    }

    private func updateRuntimeState(_ mutate: (inout AppRuntimeState) -> Void) {
        var updated = runtimeState
        mutate(&updated)
        runtimeState = updated
    }

    private func syncNativeDesktopPictures() {
        do {
            try nativeDesktopPictureManager.syncDesktopPictures(
                displays: runtimeState.activeDisplays,
                assets: assets,
                placements: placements
            )
        } catch {
            present(error)
        }
    }

    private func applicationWindows() -> [NSWindow] {
        NSApp.windows.filter { !($0 is DesktopWallpaperWindow) }
    }

    private func scheduleReconcile(trigger: StartupManager.RestoreTrigger, reason: String) {
        scheduledReconcileTask?.cancel()
        scheduledReconcileTask = Task { [weak self] in
            guard let self else { return }
            await startupManager.waitBeforeRestore(for: trigger)
            guard !Task.isCancelled, hasLoadedPersistedState else { return }

            // The decision "wallpapers were not started at launch" is state,
            // not a property of whichever trigger won the debounce race.
            guard restoreGate.shouldReconcile(
                isUserInitiated: trigger == .manual,
                startOnLaunch: preferences.startOnLaunch
            ) else {
                refreshRuntimeState()
                return
            }

            await refreshEnvironmentAndReconcile(reason: reason)
        }
    }
}
