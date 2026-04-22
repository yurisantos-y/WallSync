import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppCoordinator {
    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let assetCatalogStore: AssetCatalogStore
    @ObservationIgnored let permissionStore: FilePermissionStore
    @ObservationIgnored let posterCacheStore: PosterCacheStore
    @ObservationIgnored let metadataLoader: AssetMetadataLoader
    @ObservationIgnored let posterFrameGenerator: PosterFrameGenerator
    @ObservationIgnored let displayManager: DisplayManager
    @ObservationIgnored let energyPolicy: EnergyPolicyController
    @ObservationIgnored let startupLoginManager: StartupLoginManager

    @ObservationIgnored private let startupManager: StartupManager
    @ObservationIgnored private let reconciliationPolicy = SessionReconciliationPolicy()
    @ObservationIgnored private let powerSourceMonitor: PowerSourceMonitor
    @ObservationIgnored private let thermalMonitor: ThermalMonitor
    @ObservationIgnored private let fullscreenWindowDetector: FullscreenWindowDetector
    @ObservationIgnored private let importVideoUseCase: ImportVideoUseCase
    @ObservationIgnored private let statusItemController: StatusItemController
    @ObservationIgnored private let systemMonitor: SystemEventMonitor
    @ObservationIgnored private let sessionManager: WallpaperSessionManager
    @ObservationIgnored private var scheduledReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var openMainWindowAction: (() -> Void)?

    var assets: [WallpaperAsset] = []
    var placements: [WallpaperPlacement] = []
    var preferences: UserPreferences = .defaultValue
    var runtimeState: AppRuntimeState = .initial
    var activeSessions: [RenderSession] = []
    var startupLoginState: StartupLoginState = .disabled
    var lastErrorMessage: String?

    init() {
        let settingsStore = SettingsStore()
        let assetCatalogStore = AssetCatalogStore()
        let permissionStore = FilePermissionStore()
        let posterCacheStore = PosterCacheStore()
        let metadataLoader = AssetMetadataLoader()
        let posterFrameGenerator = PosterFrameGenerator()
        let displayManager = DisplayManager()
        let energyPolicy = EnergyPolicyController()
        let startupLoginManager = StartupLoginManager()
        let startupManager = StartupManager()
        let powerSourceMonitor = PowerSourceMonitor()
        let thermalMonitor = ThermalMonitor()
        let fullscreenWindowDetector = FullscreenWindowDetector()
        let statusItemController = StatusItemController()

        self.settingsStore = settingsStore
        self.assetCatalogStore = assetCatalogStore
        self.permissionStore = permissionStore
        self.posterCacheStore = posterCacheStore
        self.metadataLoader = metadataLoader
        self.posterFrameGenerator = posterFrameGenerator
        self.displayManager = displayManager
        self.energyPolicy = energyPolicy
        self.startupLoginManager = startupLoginManager
        self.startupManager = startupManager
        self.powerSourceMonitor = powerSourceMonitor
        self.thermalMonitor = thermalMonitor
        self.fullscreenWindowDetector = fullscreenWindowDetector
        self.statusItemController = statusItemController
        self.systemMonitor = SystemEventMonitor()

        self.importVideoUseCase = ImportVideoUseCase(
            permissionStore: permissionStore,
            metadataLoader: metadataLoader,
            posterFrameGenerator: posterFrameGenerator,
            posterCacheStore: posterCacheStore
        )

        self.sessionManager = WallpaperSessionManager(
            permissionStore: permissionStore,
            posterCacheStore: posterCacheStore,
            energyPolicy: energyPolicy
        )

        self.sessionManager.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.activeSessions = sessions
            self.updateRuntimeState {
                $0.visibleSessions = Set(sessions.filter { $0.windowState == .visible }.map(\.id))
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

    func shutdown() {
        scheduledReconcileTask?.cancel()
        sessionManager.stopAll()
        systemMonitor.stop()
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
                scheduleReconcile(trigger: .manual, reason: "asset_removed")
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
        guard let relativePath = asset.posterImageRelativePath,
              let supportDirectory = try? FileManager.default.wallpaperApplicationSupportDirectory() else {
            return nil
        }

        return supportDirectory.appendingPathComponent(relativePath)
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
        do {
            preferences = try await settingsStore.loadPreferences()
            placements = try await settingsStore.loadPlacements()
            assets = try await assetCatalogStore.loadAssets()
            startupLoginState = startupLoginManager.currentState()
            refreshRuntimeState()
        } catch {
            present(error)
        }
    }

    private func refreshRuntimeState() {
        let activeDisplays = displayManager.currentDisplays()
        updateRuntimeState {
            $0.activeDisplays = activeDisplays
            $0.powerSource = powerSourceMonitor.currentPowerSource()
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.thermalState = thermalMonitor.currentThermalState()
            $0.fullscreenDisplayUUIDs = fullscreenWindowDetector.fullscreenDisplayUUIDs(displays: activeDisplays)
        }
    }

    private func refreshEnvironmentAndReconcile(reason: String) async {
        guard runtimeState.sleepState == .awake else { return }

        refreshRuntimeState()

        await sessionManager.reconcile(
            displays: runtimeState.activeDisplays,
            assets: assets,
            placements: placements,
            preferences: preferences,
            runtimeState: runtimeState
        )
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
            sessionManager.stopAll()
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

    private func applicationWindows() -> [NSWindow] {
        NSApp.windows.filter { !($0 is DesktopWallpaperWindow) }
    }

    private func scheduleReconcile(trigger: StartupManager.RestoreTrigger, reason: String) {
        scheduledReconcileTask?.cancel()
        scheduledReconcileTask = Task { [weak self] in
            guard let self else { return }
            await startupManager.waitBeforeRestore(for: trigger)
            guard !Task.isCancelled else { return }

            if trigger == .appLaunch && !preferences.startOnLaunch && activeSessions.isEmpty {
                refreshRuntimeState()
                return
            }

            await refreshEnvironmentAndReconcile(reason: reason)
        }
    }
}
