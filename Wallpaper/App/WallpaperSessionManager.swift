import AppKit
import Foundation

@MainActor
final class WallpaperSessionManager {
    private struct SessionRuntime {
        var session: RenderSession
        var asset: WallpaperAsset
        var placement: WallpaperPlacement
        let windowController: DesktopWallpaperWindowController
        let playbackController: AVPlayerPlaybackController
        var isOccluded: Bool
        var isFullscreen: Bool
        var isPrepared: Bool
        var hasAccessScope: Bool
        var teardownTask: Task<Void, Never>?
    }

    private let permissionStore: FilePermissionStore
    private let posterCacheStore: PosterCacheStore
    private let energyPolicy: EnergyPolicyController
    private let reconciliationPolicy = SessionReconciliationPolicy()

    private var sessions: [String: SessionRuntime] = [:]
    private var currentPreferences = UserPreferences.defaultValue
    private var currentRuntimeState = AppRuntimeState.initial

    var onSessionsChanged: (([RenderSession]) -> Void)?

    init(
        permissionStore: FilePermissionStore,
        posterCacheStore: PosterCacheStore,
        energyPolicy: EnergyPolicyController
    ) {
        self.permissionStore = permissionStore
        self.posterCacheStore = posterCacheStore
        self.energyPolicy = energyPolicy
    }

    func reconcile(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement],
        preferences: UserPreferences,
        runtimeState: AppRuntimeState
    ) async {
        currentPreferences = preferences
        currentRuntimeState = runtimeState

        let desiredSessions = reconciliationPolicy.desiredSessions(
            displays: displays,
            assets: assets,
            placements: placements
        )

        let desiredDisplayIDs = Set(desiredSessions.map(\.display.displayUUID))
        let existingDisplayIDs = Set(sessions.keys)

        for removedDisplayID in existingDisplayIDs.subtracting(desiredDisplayIDs) {
            await tearDownSession(for: removedDisplayID)
        }

        for desired in desiredSessions {
            guard desired.asset.eligibility.tier != .unsupported else {
                continue
            }

            if let existing = sessions[desired.display.displayUUID],
               existing.session.assetID == desired.asset.id {
                await update(existingDisplayID: desired.display.displayUUID, with: desired)
            } else {
                await replaceSession(with: desired)
            }
        }

        publishSessions()
    }

    func stopAll() {
        let displayIDs = Array(sessions.keys)
        Task {
            for displayID in displayIDs {
                await tearDownSession(for: displayID)
            }
            publishSessions()
        }
    }

    private func update(existingDisplayID: String, with desired: DesiredWallpaperSession) async {
        guard var runtime = sessions[existingDisplayID] else { return }

        runtime.asset = desired.asset
        runtime.placement = desired.placement
        runtime.isFullscreen = currentRuntimeState.fullscreenDisplayUUIDs.contains(desired.display.displayUUID)
        runtime.windowController.updateDisplayTarget(desired.display)
        runtime.playbackController.setContentMode(desired.placement.contentMode)
        runtime.session.displayTarget = desired.display

        await applyPolicy(to: &runtime)
        sessions[existingDisplayID] = runtime
    }

    private func replaceSession(with desired: DesiredWallpaperSession) async {
        await tearDownSession(for: desired.display.displayUUID)

        let poster = await posterCacheStore.loadPoster(relativePath: desired.asset.posterImageRelativePath)

        let windowController = DesktopWallpaperWindowController(displayTarget: desired.display)
        let playbackController = AVPlayerPlaybackController(posterImage: poster)
        playbackController.attach(to: windowController.hostView, contentMode: desired.placement.contentMode)

        var runtime = SessionRuntime(
            session: RenderSession(
                id: UUID(),
                displayTarget: desired.display,
                assetID: desired.asset.id,
                windowState: .visible,
                playbackState: .preparing,
                energyMode: .animate,
                startedAt: .now,
                lastVisibilityChange: .now
            ),
            asset: desired.asset,
            placement: desired.placement,
            windowController: windowController,
            playbackController: playbackController,
            isOccluded: windowController.isOccluded,
            isFullscreen: currentRuntimeState.fullscreenDisplayUUIDs.contains(desired.display.displayUUID),
            isPrepared: false,
            hasAccessScope: false,
            teardownTask: nil
        )

        windowController.onOcclusionChange = { [weak self] isOccluded in
            guard let self else { return }
            Task { @MainActor in
                await self.handleOcclusionChange(for: desired.display.displayUUID, isOccluded: isOccluded)
            }
        }

        await applyPolicy(to: &runtime)
        sessions[desired.display.displayUUID] = runtime
    }

    private func tearDownSession(for displayID: String) async {
        guard var runtime = sessions.removeValue(forKey: displayID) else { return }

        runtime.teardownTask?.cancel()
        await teardownPlayback(for: &runtime, reason: "session_removed")
        runtime.windowController.closeWindow()
    }

    private func handleOcclusionChange(for displayID: String, isOccluded: Bool) async {
        guard var runtime = sessions[displayID] else { return }
        guard runtime.isOccluded != isOccluded else { return }
        runtime.isOccluded = isOccluded
        runtime.session.lastVisibilityChange = .now
        runtime.session.windowState = isOccluded ? .suspended : .visible
        await applyPolicy(to: &runtime)
        sessions[displayID] = runtime
        publishSessions()
    }

    private func applyPolicy(to runtime: inout SessionRuntime) async {
        runtime.isFullscreen = currentRuntimeState.fullscreenDisplayUUIDs.contains(runtime.session.displayTarget.displayUUID)
        runtime.session.displayTarget = runtime.windowController.displayTarget

        let context = systemContext(for: runtime)
        let mode = energyPolicy.mode(for: context, preferences: currentPreferences)

        switch mode {
        case .animate:
            cancelDeferredTeardown(for: &runtime)

            do {
                try await ensurePlaybackPrepared(for: &runtime)
                if runtime.session.playbackState != .animating {
                    runtime.playbackController.play()
                }
                if runtime.session.windowState != .visible {
                    runtime.windowController.show()
                    runtime.session.lastVisibilityChange = .now
                }
                runtime.session.playbackState = .animating
                runtime.session.windowState = .visible
                runtime.session.energyMode = .animate
            } catch {
                runtime.playbackController.showPoster()
                if runtime.session.windowState != .visible {
                    runtime.windowController.show()
                    runtime.session.lastVisibilityChange = .now
                }
                runtime.session.playbackState = .failed
                runtime.session.windowState = .visible
                runtime.session.energyMode = .poster
            }
        case .poster:
            cancelDeferredTeardown(for: &runtime)
            if runtime.session.playbackState != .poster || runtime.session.energyMode != .poster {
                runtime.playbackController.showPoster()
            }
            if runtime.session.windowState != .visible {
                runtime.windowController.show()
                runtime.session.lastVisibilityChange = .now
            }
            runtime.session.playbackState = .poster
            runtime.session.windowState = .visible
            runtime.session.energyMode = .poster
        case .suspend:
            runtime.playbackController.pause()
            runtime.playbackController.showPoster()
            runtime.session.playbackState = runtime.isPrepared ? .paused : .idle

            let nextWindowState: RenderSession.WindowState = runtime.isFullscreen ? .hidden : .suspended
            if runtime.session.windowState != nextWindowState {
                runtime.session.lastVisibilityChange = .now
            }

            switch nextWindowState {
            case .visible:
                runtime.windowController.show()
            case .hidden:
                runtime.windowController.hide()
            case .suspended:
                runtime.windowController.show()
            }

            runtime.session.windowState = nextWindowState
            runtime.session.energyMode = .suspend

            if (runtime.isOccluded || runtime.isFullscreen),
               energyPolicy.shouldUnloadSuspendedPlayback(for: context, preferences: currentPreferences) {
                scheduleDeferredTeardown(
                    for: &runtime,
                    after: energyPolicy.suspendedPlaybackGracePeriod(for: context, preferences: currentPreferences)
                )
            } else {
                cancelDeferredTeardown(for: &runtime)
            }
        }
    }

    private func ensurePlaybackPrepared(for runtime: inout SessionRuntime) async throws {
        guard !runtime.isPrepared else { return }

        let authorizedURL = try await permissionStore.resolveBookmark(id: runtime.asset.originalBookmarkID)
        runtime.hasAccessScope = true

        do {
            try await runtime.playbackController.prepare(with: authorizedURL)
            runtime.playbackController.attach(to: runtime.windowController.hostView, contentMode: runtime.placement.contentMode)
            runtime.isPrepared = true
            runtime.session.playbackState = .preparing
        } catch {
            if runtime.hasAccessScope {
                await permissionStore.stopAccess(for: runtime.asset.originalBookmarkID)
                runtime.hasAccessScope = false
            }
            throw error
        }
    }

    private func teardownPlayback(for runtime: inout SessionRuntime, reason: String) async {
        runtime.playbackController.teardown()
        runtime.isPrepared = false

        if runtime.hasAccessScope {
            await permissionStore.stopAccess(for: runtime.asset.originalBookmarkID)
            runtime.hasAccessScope = false
        }

        if runtime.session.playbackState != .failed {
            runtime.session.playbackState = .idle
        }
    }

    private func cancelDeferredTeardown(for runtime: inout SessionRuntime) {
        runtime.teardownTask?.cancel()
        runtime.teardownTask = nil
    }

    private func scheduleDeferredTeardown(for runtime: inout SessionRuntime, after delay: Duration) {
        cancelDeferredTeardown(for: &runtime)
        let displayID = runtime.session.displayTarget.displayUUID

        runtime.teardownTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.executeDeferredTeardown(for: displayID)
        }
    }

    private func executeDeferredTeardown(for displayID: String) async {
        guard var runtime = sessions[displayID] else { return }
        runtime.teardownTask = nil

        guard runtime.session.energyMode == .suspend,
              runtime.isPrepared,
              runtime.isOccluded || runtime.isFullscreen else {
            sessions[displayID] = runtime
            return
        }

        await teardownPlayback(for: &runtime, reason: "invisible_grace_elapsed")
        sessions[displayID] = runtime
        publishSessions()
    }

    private func publishSessions() {
        onSessionsChanged?(sessions.values.map(\.session).sorted { $0.displayTarget.localizedName < $1.displayTarget.localizedName })
    }

    private func systemContext(for runtime: SessionRuntime) -> SystemContext {
        SystemContext(
            onBattery: currentRuntimeState.powerSource == .battery,
            lowPowerMode: currentRuntimeState.lowPowerMode,
            thermalState: currentRuntimeState.thermalState,
            isOccluded: runtime.isOccluded,
            isFullscreen: runtime.isFullscreen,
            assetIsHeavy: runtime.asset.eligibility.isHeavy,
            isPrimaryDisplay: runtime.session.displayTarget.isPrimary,
            activeDisplayCount: currentRuntimeState.activeDisplays.count
        )
    }
}
