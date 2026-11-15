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
    @ObservationIgnored private let importPipeline: AssetImportPipeline
    @ObservationIgnored private var optimizationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var optimizationQueueTail: Task<Void, Never>?
    @ObservationIgnored private var reoptimizationAttempted: Set<UUID> = []
    /// The recipe each asset was last (re)optimized for in this launch, so an
    /// edit that cannot be applied is not retried on every event.
    @ObservationIgnored private var recipeAttempted: [UUID: EditRecipe] = [:]
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let statusItemController: StatusItemController
    @ObservationIgnored private let systemMonitor: SystemEventMonitor
    @ObservationIgnored private let sessionManager: WallpaperSessionManager
    @ObservationIgnored private let janitor: AssetStorageJanitor
    @ObservationIgnored private let metricsSubscriber = MetricsSubscriber()
    @ObservationIgnored private var scheduledReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reevaluationTask: Task<Void, Never>?
    @ObservationIgnored private var occlusionPollTimer: Timer?
    @ObservationIgnored private var restoreGate = StartupRestoreGate()
    @ObservationIgnored private var startupIssues: [StorageIssue] = []
    @ObservationIgnored private var hasLoadedPersistedState = false
    @ObservationIgnored private var openMainWindowAction: (() -> Void)?

    var assets: [WallpaperAsset] = []
    var placements: [WallpaperPlacement] = []
    var playlists: [WallpaperPlaylist] = []
    /// Temporary instruction from a Focus filter; never persisted into the
    /// user's assignments.
    var focusOverride: FocusOverride?
    /// What every display shows right now, as decided by `WallpaperResolver`.
    private(set) var resolution = WallpaperResolver.Output()
    var preferences: UserPreferences = .defaultValue
    var runtimeState: AppRuntimeState = .initial
    var activeSessions: [RenderSession] = []
    var startupLoginState: StartupLoginState = .disabled
    var lastErrorMessage: String?
    /// Background optimizations in flight, keyed by asset.
    var importActivities: [UUID: ImportActivity] = [:]

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

        self.importPipeline = AssetImportPipeline(
            storage: storage,
            permissionStore: permissionStore,
            metadataLoader: metadataLoader,
            posterFrameGenerator: posterFrameGenerator,
            posterCacheStore: posterCacheStore,
            videoAssetOptimizer: videoAssetOptimizer
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
            self.updateOcclusionPolling()
            self.statusItemController.refresh()
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
        self.statusItemController.onTogglePause = { [weak self] in
            guard let self else { return }
            self.setUserPaused(!self.runtimeState.isUserPaused)
        }
        self.statusItemController.statusProvider = { [weak self] in
            guard let self else {
                return StatusItemController.Status(isPaused: false, summary: "", hasWallpapers: false)
            }
            return StatusItemController.Status(
                isPaused: self.runtimeState.isUserPaused,
                summary: self.statusSummary.localizedLabel,
                hasWallpapers: !self.activeSessions.isEmpty
            )
        }
        self.statusItemController.menuContentProvider = { [weak self] in
            self?.menuContent() ?? StatusItemController.MenuContent()
        }
        self.statusItemController.onApplyWallpaper = { [weak self] assetID, displayUUID in
            self?.applyWallpaper(assetID, toDisplayUUID: displayUUID)
        }
        self.statusItemController.onQuit = {
            NSApp.terminate(nil)
        }
    }

    func start() {
        statusItemController.start()
        systemMonitor.start()
        metricsSubscriber.start()
        Log.session.notice("WallSync \(Self.appVersion, privacy: .public) started")

        updateRuntimeState {
            $0.isScreenLocked = SystemEventMonitor.isScreenCurrentlyLocked
        }

        Task {
            await loadPersistedState()
            scheduleReconcile(trigger: .appLaunch, reason: "initial_restore")
        }
    }

    /// Returns once every window, player and security scope has been released.
    func shutdown() async {
        isShuttingDown = true
        optimizationTasks.values.forEach { $0.cancel() }
        scheduledReconcileTask?.cancel()
        reevaluationTask?.cancel()
        occlusionPollTimer?.invalidate()
        occlusionPollTimer = nil
        systemMonitor.stop()
        metricsSubscriber.stop()
        await sessionManager.stopAll()
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Plain-text snapshot of the runtime state, for support requests.
    func diagnosticsSummary() -> String {
        DiagnosticsSummary.text(
            appVersion: Self.appVersion,
            runtimeState: runtimeState,
            preferences: preferences,
            sessions: activeSessions,
            assets: assets
        )
    }

    var statusSummary: StatusSummary {
        StatusSummary.make(sessions: activeSessions, isUserPaused: runtimeState.isUserPaused)
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

    // MARK: - Import

    private enum OptimizationKind {
        /// First rendition of a video imported in this session.
        case initialImport
        /// First rendition of an asset left pending by an earlier session.
        case resume
        /// A better rendition of an asset that already plays.
        case reoptimization
    }

    /// Asks for one or more files and imports them.
    func importVideos() {
        importVideos(at: AssetImportPipeline.chooseFiles())
    }

    /// Imports the given files (open panel or drag and drop). Each asset shows
    /// up in the library at once and is optimized in the background.
    func importVideos(at urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task {
            for url in urls {
                do {
                    let asset = try await importPipeline.register(
                        url: url,
                        maximumPixelSize: displayManager.currentDisplays().largestPixelSize
                    )

                    assets.insert(asset, at: 0)
                    try await assetCatalogStore.saveAssets(assets)

                    if placements.isEmpty {
                        placements = [WallpaperPlacement(assetID: asset.id, scope: .allDisplays)]
                        try await settingsStore.savePlacements(placements)
                    }

                    enqueueOptimization(for: asset.id, kind: .initialImport)
                } catch {
                    present(error)
                }
            }

            await reconcileNow(reason: "asset_imported")
        }
    }

    func cancelImport(of asset: WallpaperAsset) {
        optimizationTasks[asset.id]?.cancel()
    }

    func importActivity(for asset: WallpaperAsset) -> ImportActivity? {
        importActivities[asset.id]
    }

    /// Optimizations run one at a time: transcoding is the most expensive
    /// thing the app does, and several at once would only compete.
    private func enqueueOptimization(for assetID: UUID, kind: OptimizationKind) {
        guard optimizationTasks[assetID] == nil else { return }

        importActivities[assetID] = ImportActivity(
            progress: 0,
            isQueued: true,
            isReoptimization: kind == .reoptimization,
            isApplyingEdits: kind == .reoptimization
                && (assets.first { $0.id == assetID }).map(OptimizationPlanner.isStale(asset:)) == true
        )

        let previous = optimizationQueueTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.runOptimization(for: assetID, kind: kind)
        }
        optimizationTasks[assetID] = task
        optimizationQueueTail = task
    }

    private func runOptimization(for assetID: UUID, kind: OptimizationKind) async {
        defer {
            importActivities[assetID] = nil
            optimizationTasks[assetID] = nil
            // The recipe may have been edited again while this one ran.
            scheduleMaintenanceOptimizations()
        }

        guard let asset = assets.first(where: { $0.id == assetID }) else { return }
        guard !Task.isCancelled else {
            await handleCancelledOptimization(of: asset, kind: kind)
            return
        }

        importActivities[assetID]?.isQueued = false

        do {
            let rendition = try await importPipeline.optimize(
                asset: asset,
                maximumPixelSize: maximumPixelSize(for: assetID, displays: displayManager.currentDisplays()),
                quality: preferences.playbackQuality,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.importActivities[assetID]?.progress = fraction
                    }
                }
            )

            guard let existingIndex = assets.firstIndex(where: { $0.id == assetID }) else {
                // Removed from the library while it was being optimized.
                await janitor.removeFile(relativePath: rendition.relativePath)
                return
            }

            let previousPath = assets[existingIndex].optimizedPlayback?.relativePath
            let previousRecipe = assets[existingIndex].optimizedPlayback?.recipe ?? .empty
            let previousPosterPaths = [assets[existingIndex].posterImageRelativePath, assets[existingIndex].thumbnailRelativePath].compactMap { $0 }

            // Different edits show a different picture: the poster comes
            // from the new rendition, not from the start of the original.
            let newPoster: StoredPoster? = rendition.recipe == previousRecipe
                ? nil
                : await importPipeline.makePoster(
                    fromRenditionAt: storage.url(forRelativePath: rendition.relativePath),
                    assetID: assetID,
                    maximumPixelSize: displayManager.currentDisplays().largestPixelSize
                )
            guard let index = assets.firstIndex(where: { $0.id == assetID }) else {
                await janitor.removeFile(relativePath: rendition.relativePath)
                for path in [newPoster?.posterPath, newPoster?.thumbnailPath].compactMap({ $0 }) {
                    await janitor.removeFile(relativePath: path)
                }
                return
            }

            updateAssets {
                $0[index].optimizedPlayback = rendition
                $0[index].optimizationState = .ready
                $0[index].originalUnavailable = false
                if let newPoster {
                    $0[index].posterImageRelativePath = newPoster.posterPath
                    $0[index].thumbnailRelativePath = newPoster.thumbnailPath
                }
            }
            try await assetCatalogStore.saveAssets(assets)
            if newPoster != nil {
                for path in previousPosterPaths {
                    await posterCacheStore.evict(relativePath: path)
                    ThumbnailCache.shared.evict(storage.url(forRelativePath: path))
                }
            }

            // Sessions switch to the new file without interrupting playback;
            // only then is the previous rendition deleted.
            await reconcileRespectingGate(reason: "rendition_ready")
            if let previousPath, previousPath != rendition.relativePath {
                await janitor.removeFile(relativePath: previousPath)
            }
            if newPoster != nil {
                for path in previousPosterPaths {
                    await janitor.removeFile(relativePath: path)
                }
            }
        } catch is CancellationError {
            await handleCancelledOptimization(of: asset, kind: kind)
        } catch {
            await handleFailedOptimization(of: asset, kind: kind, error: error)
        }
    }

    private func handleCancelledOptimization(of asset: WallpaperAsset, kind: OptimizationKind) async {
        Log.importing.info("asset \(asset.id.uuidString, privacy: .public): optimization cancelled")
        // Quitting mid-import keeps the asset; it resumes at next launch.
        guard !isShuttingDown, kind == .initialImport else { return }
        await removeAssetCompletely(asset)
    }

    private func handleFailedOptimization(of asset: WallpaperAsset, kind: OptimizationKind, error: Error) async {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }

        switch kind {
        case .reoptimization:
            // Keep the current rendition; flag it in the library if the
            // reason is that the original can no longer be reached.
            if case ImportError.originalUnavailable = error {
                updateAssets { $0[index].originalUnavailable = true }
                try? await assetCatalogStore.saveAssets(assets)
            }
            // Edits the user asked for must not fail silently.
            if OptimizationPlanner.isStale(asset: assets[index]) {
                Log.importing.error("asset \(asset.id.uuidString, privacy: .public): edits could not be applied: \(error.localizedDescription, privacy: .public)")
                if case ImportError.originalUnavailable = error {
                    present(error)
                } else {
                    present(ImportError.editsFailed(name: asset.displayName))
                }
            }

        case .initialImport, .resume:
            let originalIsPlayable = asset.eligibility.tier != .unsupported
            if kind == .initialImport && !originalIsPlayable {
                // Neither playable nor convertible: no dead entry is kept.
                await removeAssetCompletely(asset)
                present(ImportError.cannotBePlayedOrConverted(name: asset.displayName))
                return
            }

            updateAssets {
                $0[index].optimizationState = .failed
                if case ImportError.originalUnavailable = error {
                    $0[index].originalUnavailable = true
                }
            }
            try? await assetCatalogStore.saveAssets(assets)
            if kind == .initialImport {
                present(ImportError.optimizationFailedPlayingOriginal(name: asset.displayName))
            }
            await reconcileRespectingGate(reason: "optimization_failed")
        }
    }

    /// Queues work that the current displays and preferences call for:
    /// assets that never got a rendition, and assets in use whose rendition
    /// is now too small (bigger display connected) or too slow (frame-rate
    /// ceiling raised) while the source has more to offer.
    private func scheduleMaintenanceOptimizations() {
        guard hasLoadedPersistedState, !isShuttingDown else { return }

        for asset in assets where asset.optimizationState == .pending {
            enqueueOptimization(for: asset.id, kind: .resume)
        }

        // Edited since the rendition was made: apply the recipe, whether or
        // not the asset is on a display right now.
        for asset in assets
        where asset.optimizationState == .ready
            && optimizationTasks[asset.id] == nil
            && OptimizationPlanner.isStale(asset: asset)
            && recipeAttempted[asset.id] != asset.editRecipe {
            recipeAttempted[asset.id] = asset.editRecipe
            Log.importing.info("asset \(asset.id.uuidString, privacy: .public): edits changed, producing a new rendition")
            enqueueOptimization(for: asset.id, kind: .reoptimization)
        }

        let displays = runtimeState.activeDisplays
        guard !displays.isEmpty else { return }
        let assetsInUse = Set(placements.filter(\.isEnabled).map(\.assetID))
            .union(resolution.displays.map(\.assetID))
            .union(playlists.flatMap(\.referencedAssetIDs))

        for asset in assets
        where assetsInUse.contains(asset.id)
            && !reoptimizationAttempted.contains(asset.id)
            && OptimizationPlanner.needsReoptimization(
                asset: asset,
                maximumPixelSize: self.maximumPixelSize(for: asset.id, displays: displays),
                quality: preferences.playbackQuality
            ) {
            // One attempt per launch: an unreachable original is not retried
            // on every display event.
            reoptimizationAttempted.insert(asset.id)
            Log.importing.info("asset \(asset.id.uuidString, privacy: .public): a better rendition is possible, reoptimizing")
            enqueueOptimization(for: asset.id, kind: .reoptimization)
        }
    }

    /// Pixel size a rendition of the asset is produced for: the largest
    /// display, or the whole span when the asset stretches across displays.
    private func maximumPixelSize(for assetID: UUID, displays: [DisplayTarget]) -> CGSize {
        let spanned = Set(
            resolution.displays
                .filter { $0.assetID == assetID && $0.placement.spansDisplays }
                .map(\.displayUUID)
        )
        let spanDisplays = displays.filter { spanned.contains($0.displayUUID) }
        guard spanDisplays.count >= 2 else { return displays.largestPixelSize }
        return PanoramaLayout.targetPixelSize(displays: spanDisplays)
    }

    /// The saved wallpaper for every display, when there is one.
    var globalPlacement: WallpaperPlacement? {
        placements.first(where: \.isGlobal)
    }

    /// Turns the panorama on or off for the "all displays" wallpaper and
    /// sets which part of the video stays visible.
    func updatePanorama(spansDisplays: Bool? = nil, offset: CGPoint? = nil) {
        guard let index = placements.firstIndex(where: \.isGlobal) else { return }
        var placement = placements[index]
        if let spansDisplays { placement.spansDisplays = spansDisplays }
        if let offset {
            placement.panoramaOffset = CGPoint(x: min(max(offset.x, -1), 1), y: min(max(offset.y, -1), 1))
        }
        guard placement != placements[index] else { return }
        updatePlacements { $0[index] = placement }
        // A span may call for a larger rendition than a single display did.
        reoptimizationAttempted.removeAll()
        persistPlacementsAndReconcile(reason: "panorama_changed")
    }

    /// Stores new edits for an asset. The current rendition keeps playing
    /// while a new one is produced in the background, then playback switches
    /// to it without interruption.
    func updateEditRecipe(_ recipe: EditRecipe, for assetID: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        let normalized = recipe.normalized(duration: assets[index].duration)
        guard assets[index].editRecipe != normalized else { return }

        updateAssets {
            $0[index].editRecipe = normalized
            $0[index].originalUnavailable = false
        }
        recipeAttempted[assetID] = nil

        Task {
            do {
                try await assetCatalogStore.saveAssets(assets)
            } catch {
                present(error)
            }
            scheduleMaintenanceOptimizations()
        }
    }

    /// Opens the original file of an asset for the editor. Returns `nil`
    /// when it can no longer be reached; balance with `endEditing(_:)`.
    func beginEditing(_ asset: WallpaperAsset) async -> URL? {
        let url = await importPipeline.beginAccessToOriginal(of: asset)
        if url == nil, let index = assets.firstIndex(where: { $0.id == asset.id }), !assets[index].originalUnavailable {
            updateAssets { $0[index].originalUnavailable = true }
            try? await assetCatalogStore.saveAssets(assets)
        }
        return url
    }

    func endEditing(_ asset: WallpaperAsset) async {
        await importPipeline.endAccessToOriginal(of: asset)
    }

    func removeAsset(_ asset: WallpaperAsset) {
        Task {
            await removeAssetCompletely(asset)
        }
    }

    private func removeAssetCompletely(_ asset: WallpaperAsset) async {
        optimizationTasks[asset.id]?.cancel()

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
        await reconcileRespectingGate(reason: "asset_removed")
        // Read the latest record: a rendition may have landed meanwhile.
        await deleteStoredData(of: asset)
    }

    /// Frees everything an asset owns: optimized video, poster, cached poster
    /// and the security-scoped bookmark of the original file.
    private func deleteStoredData(of asset: WallpaperAsset) async {
        await posterCacheStore.evict(relativePath: asset.posterImageRelativePath)
        ThumbnailCache.shared.evict(thumbnailURL(for: asset))
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

    /// What the menu bar shows while it is open.
    private func menuContent() -> StatusItemController.MenuContent {
        let active = Set(resolution.displays.map(\.assetID))
        let assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var content = StatusItemController.MenuContent()
        content.recents = RecentWallpapers.items(assets: assets, activeAssetIDs: active).map { item in
            StatusItemController.RecentEntry(
                assetID: item.assetID,
                name: item.name,
                isActive: item.isActive,
                thumbnailURL: assetsByID[item.assetID].flatMap(thumbnailURL(for:))
            )
        }
        content.displays = runtimeState.activeDisplays.map { ($0.displayUUID, $0.localizedName) }
        return content
    }

    /// Puts a wallpaper on one display, or on every display when
    /// `displayUUID` is `nil` (per-display choices are then cleared, so that
    /// "all displays" means all of them).
    func applyWallpaper(_ assetID: UUID, toDisplayUUID displayUUID: String?) {
        guard assets.contains(where: { $0.id == assetID }) else { return }

        if let displayUUID {
            if let display = runtimeState.activeDisplays.first(where: { $0.displayUUID == displayUUID }) {
                assignAsset(assetID, to: display)
            }
            return
        }

        updatePlacements { placements in
            placements.removeAll { !$0.isGlobal }
        }
        setGlobalAsset(assetID)
    }

    /// Records that a wallpaper was just put on a display.
    private func markUsed(_ assetID: UUID?) {
        guard let assetID, let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        updateAssets { $0[index].lastUsedAt = .now }
        Task {
            try? await assetCatalogStore.saveAssets(assets)
        }
    }

    func setGlobalAsset(_ assetID: UUID?) {
        markUsed(assetID)
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
                // Choosing a fixed wallpaper ends a playlist on this slot.
                placements[existingIndex].playlistID = nil
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

    /// The wallpaper the display shows now, after playlists and Focus.
    func effectiveAsset(for display: DisplayTarget) -> WallpaperAsset? {
        let assetID = resolution.content(forDisplayUUID: display.displayUUID)?.assetID ?? assignedAssetID(for: display)
        guard let assetID else { return nil }
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

    /// The small library thumbnail, or the full poster for assets imported
    /// before thumbnails existed.
    func thumbnailURL(for asset: WallpaperAsset) -> URL? {
        (asset.thumbnailRelativePath ?? asset.posterImageRelativePath).map(storage.url(forRelativePath:))
    }

    /// Changes how fast one wallpaper plays. Immediate: no new rendition.
    func updatePlaybackRate(_ rate: Double, for assetID: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        let range = WallpaperAsset.playbackRateRange
        let clamped = min(max(rate, range.lowerBound), range.upperBound)
        guard assets[index].playbackRate != clamped else { return }
        updateAssets { $0[index].playbackRate = clamped }
        persistAssetsAndReconcile(reason: "playback_rate_changed")
    }

    /// Changes the global dimming. Takes effect at once: no new rendition.
    func updateDimming(_ mutate: (inout DimmingSettings) -> Void) {
        var dimming = preferences.dimming
        mutate(&dimming)
        dimming.amount = min(max(dimming.amount, 0), DimmingSettings.maximum)
        guard dimming != preferences.dimming else { return }
        updatePreferences { $0.dimming = dimming }
        persistPreferencesAndReconcile(reason: "dimming_changed")
    }

    /// Per-wallpaper dimming; `nil` follows the global setting.
    func updateDimmingOverride(_ amount: Double?, for assetID: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        let clamped = amount.map { min(max($0, 0), DimmingSettings.maximum) }
        guard assets[index].dimmingOverride != clamped else { return }
        updateAssets { $0[index].dimmingOverride = clamped }
        persistAssetsAndReconcile(reason: "dimming_override_changed")
    }

    func updatePlaybackQuality(_ quality: UserPreferences.PlaybackQuality) {
        updatePreferences {
            $0.playbackQuality = quality
        }
        // A higher ceiling may allow better renditions of assets in use.
        reoptimizationAttempted.removeAll()
        persistPreferencesAndReconcile(reason: "playback_quality_changed")
    }

    func assignAsset(_ assetID: UUID?, to display: DisplayTarget) {
        markUsed(assetID)
        updatePlacements { placements in
            if let existingIndex = placements.firstIndex(where: {
                if case let .specificDisplay(displayUUID) = $0.scope {
                    return displayUUID == display.displayUUID
                }
                return false
            }) {
                if let assetID {
                    placements[existingIndex].assetID = assetID
                    placements[existingIndex].playlistID = nil
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

    func updatePauseWhenReduceMotion(_ enabled: Bool) {
        updatePreferences {
            $0.pauseWhenReduceMotion = enabled
        }
        persistPreferencesAndReconcile(reason: "reduce_motion_preference_changed")
    }

    /// Pauses or resumes every wallpaper (menu bar control). Not persisted:
    /// a relaunch starts unpaused.
    func setUserPaused(_ paused: Bool) {
        guard runtimeState.isUserPaused != paused else { return }
        updateRuntimeState { $0.isUserPaused = paused }
        statusItemController.refresh()
        Task {
            await reconcileNow(reason: paused ? "user_paused" : "user_resumed")
        }
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
        Log.storage.info("loaded \(self.assets.count) assets, \(self.placements.count) placements, issues=\(self.startupIssues.count)")
        if !startupIssues.isEmpty {
            lastErrorMessage = startupIssues.map(\.message).joined(separator: "\n")
        }

        // Never sweep "orphans" against a catalog that failed to load: every
        // file would look unreferenced.
        if loadedAssets.issue == nil && startupIssues.allSatisfy({ if case .storageUnavailable = $0 { return false } else { return true } }) {
            let reclaimed = await janitor.removeOrphans(keeping: assets)
            if reclaimed > 0 {
                Log.storage.notice("removed orphaned media, reclaimed \(reclaimed) bytes")
            }
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
            $0.reduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            $0.isDarkAppearance = SystemEventMonitor.isDarkAppearance
            // Safety net: if the "unlocked" notification was missed, the
            // session dictionary still tells the truth.
            if $0.isScreenLocked && !SystemEventMonitor.isScreenCurrentlyLocked {
                $0.isScreenLocked = false
            }
        }
    }

    /// Runs the one function that decides what each display shows.
    private func resolveWallpapers() {
        let resolved = WallpaperResolver.resolve(
            WallpaperResolver.Input(
                displays: runtimeState.activeDisplays,
                placements: placements,
                playlists: playlists,
                assets: assets,
                focus: focusOverride,
                isUserPaused: runtimeState.isUserPaused,
                now: .now,
                calendar: .current,
                isDarkAppearance: runtimeState.isDarkAppearance
            )
        )
        if resolved != resolution {
            resolution = resolved
        }
        let focusPaused = resolved.pause == .focus
        if runtimeState.isFocusPaused != focusPaused {
            updateRuntimeState { $0.isFocusPaused = focusPaused }
        }
    }

    private func makeReconcileRequest(reason: String) -> SessionReconcileRequest {
        refreshRuntimeState()
        resolveWallpapers()
        syncNativeDesktopPictures()

        return SessionReconcileRequest(
            displays: runtimeState.activeDisplays,
            assets: assets,
            placements: resolution.placements,
            preferences: preferences,
            runtimeState: runtimeState,
            reason: reason
        )
    }

    private func submitReconcile(reason: String) {
        sessionManager.submit(makeReconcileRequest(reason: reason))
        scheduleMaintenanceOptimizations()
    }

    private func refreshEnvironmentAndReconcile(reason: String) async {
        await sessionManager.reconcile(makeReconcileRequest(reason: reason))
        scheduleMaintenanceOptimizations()
    }

    /// Reconciles now and waits, without lifting a suppressed launch restore.
    private func reconcileRespectingGate(reason: String) async {
        guard restoreGate.shouldReconcile(isUserInitiated: false, startOnLaunch: preferences.startOnLaunch) else {
            return
        }
        await refreshEnvironmentAndReconcile(reason: reason)
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

    private func persistAssetsAndReconcile(reason: String) {
        Task {
            do {
                try await assetCatalogStore.saveAssets(assets)
                await reconcileRespectingGate(reason: reason)
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
        Log.energy.debug("system event: \(String(describing: event), privacy: .public)")
        switch event {
        case .willSleep:
            // Pause and keep windows and posters; the energy policy decides
            // whether players are released. Nothing is rebuilt on wake.
            updateRuntimeState { $0.sleepState = .sleeping }
            reconcileImmediately(reason: "will_sleep")
        case .didWake:
            updateRuntimeState { $0.sleepState = .awake }
            reconcileImmediately(reason: "did_wake")
        case let .screenLockChanged(isLocked):
            updateRuntimeState {
                $0.isScreenLocked = isLocked
                // Unlocking always ends the screen saver.
                if !isLocked { $0.isScreenSaverActive = false }
            }
            reconcileImmediately(reason: isLocked ? "screen_locked" : "screen_unlocked")
        case let .screenSaverChanged(isActive):
            updateRuntimeState { $0.isScreenSaverActive = isActive }
            reconcileImmediately(reason: isActive ? "screensaver_started" : "screensaver_stopped")
        case let .displaySleepChanged(isAsleep):
            updateRuntimeState { $0.displaysAsleep = isAsleep }
            reconcileImmediately(reason: isAsleep ? "displays_asleep" : "displays_awake")
        case let .sessionActiveChanged(isActive):
            updateRuntimeState { $0.isSessionInactive = !isActive }
            reconcileImmediately(reason: isActive ? "session_active" : "session_inactive")
        case .accessibilityOptionsChanged:
            scheduleReconcile(trigger: .powerChange, reason: "accessibility_changed")
        case .appearanceChanged:
            // The short debounce also lets AppKit pick the new appearance up.
            scheduleReconcile(trigger: .powerChange, reason: "appearance_changed")
        case .clockChanged:
            scheduleReconcile(trigger: .powerChange, reason: "clock_changed")
        case .displaysChanged:
            scheduleReconcile(trigger: .displayChange, reason: "display_changed")
        case .activeSpaceChanged:
            scheduleReconcile(trigger: .activeSpaceChange, reason: "space_changed")
        case .applicationActivated:
            // A newly frontmost app is the usual way a window ends up
            // covering the desktop; give its window time to appear.
            scheduleReevaluation(after: .milliseconds(350), reason: "app_activated")
        case .powerStateChanged:
            scheduleReconcile(trigger: .powerChange, reason: "power_changed")
        case .thermalStateChanged:
            scheduleReconcile(trigger: .thermalChange, reason: "thermal_changed")
        }
    }

    /// Reconciles without debounce. Used for transitions that must take
    /// effect at once (lock, sleep, display sleep) and never start wallpapers
    /// that the launch preference is holding back.
    private func reconcileImmediately(reason: String) {
        guard hasLoadedPersistedState else { return }
        scheduledReconcileTask?.cancel()
        guard restoreGate.shouldReconcile(isUserInitiated: false, startOnLaunch: preferences.startOnLaunch) else {
            return
        }
        submitReconcile(reason: reason)
    }

    private func scheduleReevaluation(after delay: Duration, reason: String) {
        reevaluationTask?.cancel()
        reevaluationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sessionManager.reevaluate(reason: reason)
        }
    }

    /// Runs the periodic window-list check only while it can change something.
    private func updateOcclusionPolling() {
        let shouldPoll = OcclusionPollingPolicy.shouldPoll(sessions: activeSessions)
        if shouldPoll, occlusionPollTimer == nil {
            let timer = Timer(timeInterval: OcclusionPollingPolicy.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionManager.reevaluate(reason: "occlusion_poll")
                }
            }
            timer.tolerance = OcclusionPollingPolicy.tolerance
            RunLoop.main.add(timer, forMode: .common)
            occlusionPollTimer = timer
            Log.energy.debug("occlusion polling started")
        } else if !shouldPoll, let timer = occlusionPollTimer {
            timer.invalidate()
            occlusionPollTimer = nil
            Log.energy.debug("occlusion polling stopped")
        }
    }

    private func present(_ error: Error) {
        Log.session.error("presenting error: \(error.localizedDescription, privacy: .public)")
        let message = error.localizedDescription
        if let current = lastErrorMessage, !current.isEmpty {
            // Several imports can fail in a row; keep every message.
            if !current.contains(message) {
                lastErrorMessage = current + "\n" + message
            }
        } else {
            lastErrorMessage = message
        }
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
                placements: resolution.placements,
                dimming: preferences.dimming,
                isDarkAppearance: runtimeState.isDarkAppearance
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
                scheduleMaintenanceOptimizations()
                return
            }

            await refreshEnvironmentAndReconcile(reason: reason)
        }
    }
}
