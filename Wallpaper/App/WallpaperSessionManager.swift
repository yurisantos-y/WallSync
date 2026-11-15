import CoreGraphics
import Foundation

/// The complete desired state handed to the session manager. A newer request
/// always supersedes an older one that has not been applied yet.
struct SessionReconcileRequest: Sendable {
    var displays: [DisplayTarget]
    var assets: [WallpaperAsset]
    var placements: [WallpaperPlacement]
    var preferences: UserPreferences
    var runtimeState: AppRuntimeState
    /// What caused this reconcile; only used for logging.
    var reason: String = "unspecified"
}

/// Owns every wallpaper window and playback engine.
///
/// All mutations go through a single command queue consumed by one task, so a
/// command always runs to completion before the next one starts. That removes
/// the copy / await / write-back races of the previous design: there is no way
/// for two reconciles (or a reconcile and an occlusion change) to interleave
/// and leave an orphaned window, player or security scope behind.
@MainActor
final class WallpaperSessionManager {
    private final class SessionRuntime {
        var session: RenderSession
        var asset: WallpaperAsset
        var placement: WallpaperPlacement
        let surface: any WallpaperSurface
        var mode: SessionMode = .suspend
        var modeReason: SessionModeReason = .none
        var isOccluded = false
        var isFullscreen = false
        var posterPath: String?
        var isAttached = false

        init(session: RenderSession, asset: WallpaperAsset, placement: WallpaperPlacement, surface: any WallpaperSurface) {
            self.session = session
            self.asset = asset
            self.placement = placement
            self.surface = surface
            self.posterPath = asset.posterImageRelativePath
        }
    }

    /// One decode pipeline, shared by every session that shows the same video.
    private final class PlaybackGroup {
        let key: String
        var asset: WallpaperAsset
        let engine: any SharedPlaybackEngine
        var isPrepared = false
        var isPlaying = false
        var source: RenderSession.PlaybackSource?
        var scopedBookmarkID: UUID?
        var optimizedUnavailable = false
        var prepareFailed = false
        var resumeTime: TimeInterval = 0
        var unloadTask: Task<Void, Never>?
        var unloadToken = 0

        init(key: String, asset: WallpaperAsset, engine: any SharedPlaybackEngine) {
            self.key = key
            self.asset = asset
            self.engine = engine
        }
    }

    private enum Command {
        case apply
        case stop(sequence: Int, CheckedContinuation<Void, Never>)
        case unload(groupKey: String, token: Int)
        case playbackFailed(groupKey: String)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let environment: any SessionEnvironment
    private let permissionStore: any PermissionStoring
    private let energyPolicy: EnergyPolicyController
    private let sleep: @Sendable (Duration) async -> Void
    private let reconciliationPolicy = SessionReconciliationPolicy()
    private let playbackEvaluator = PlaybackEligibilityEvaluator()
    private let occlusionDetector = DisplayOcclusionDetector()
    private let fullscreenDetector = FullscreenWindowDetector()
    private var lastFullscreenDisplayUUIDs: Set<String> = []

    private var sessions: [String: SessionRuntime] = [:]
    private var groups: [String: PlaybackGroup] = [:]

    private let commandContinuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    private var requestSequence = 0
    private var pendingRequest: (request: SessionReconcileRequest, sequence: Int)?
    private var activeRequest: (request: SessionReconcileRequest, sequence: Int)?
    private var applyQueued = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Number of reconcile passes actually executed; lets tests verify coalescing.
    private(set) var appliedReconcileCount = 0

    var onSessionsChanged: (([RenderSession]) -> Void)?
    /// Reports which displays are covered by a fullscreen window, as seen by
    /// the most recent reconcile.
    var onFullscreenDisplaysChanged: ((Set<String>) -> Void)?

    init(
        environment: any SessionEnvironment,
        permissionStore: any PermissionStoring,
        energyPolicy: EnergyPolicyController,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.environment = environment
        self.permissionStore = permissionStore
        self.energyPolicy = energyPolicy
        self.sleep = sleep

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commandContinuation = continuation
        worker = Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.process(command)
            }
        }
    }

    deinit {
        commandContinuation.finish()
        worker?.cancel()
    }

    // MARK: - Public API

    /// Records the desired state and returns immediately. If several requests
    /// arrive while a reconcile is running, only the most recent is applied.
    func submit(_ request: SessionReconcileRequest) {
        requestSequence += 1
        pendingRequest = (request, requestSequence)
        enqueueApply()
    }

    /// Same as `submit`, but returns once a reconcile that includes this
    /// request (or a newer one) has finished.
    func reconcile(_ request: SessionReconcileRequest) async {
        requestSequence += 1
        pendingRequest = (request, requestSequence)
        await withCheckedContinuation { continuation in
            applyWaiters.append(continuation)
            enqueueApply()
        }
    }

    /// Tears down every window and player. Returns when cleanup has finished,
    /// so termination can wait for it.
    func stopAll() async {
        let sequence = requestSequence
        // A request submitted after this point needs its own apply token,
        // queued behind the stop.
        applyQueued = false
        await withCheckedContinuation { continuation in
            commandContinuation.yield(.stop(sequence: sequence, continuation))
        }
    }

    /// Re-applies the current desired state against a fresh look at the
    /// environment (window list, occlusion). Cheap when nothing changed.
    func reevaluate(reason: String) {
        guard activeRequest != nil || pendingRequest != nil else { return }
        if pendingRequest == nil {
            activeRequest?.request.reason = reason
        }
        enqueueApply()
    }

    /// Returns once every command enqueued so far has been processed.
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            commandContinuation.yield(.barrier(continuation))
        }
    }

    var currentSessions: [RenderSession] {
        sessions.values.map(\.session).sorted { lhs, rhs in
            lhs.displayTarget.localizedName == rhs.displayTarget.localizedName
                ? lhs.displayTarget.displayUUID < rhs.displayTarget.displayUUID
                : lhs.displayTarget.localizedName < rhs.displayTarget.localizedName
        }
    }

    // MARK: - Command loop

    private func enqueueApply() {
        guard !applyQueued else { return }
        applyQueued = true
        commandContinuation.yield(.apply)
    }

    private func process(_ command: Command) async {
        switch command {
        case .apply:
            applyQueued = false
            let waiters = applyWaiters
            applyWaiters = []

            if let pendingRequest {
                activeRequest = pendingRequest
                self.pendingRequest = nil
            }
            if let activeRequest {
                await apply(activeRequest.request)
            }
            waiters.forEach { $0.resume() }

        case let .stop(sequence, continuation):
            Log.session.info("stopping all sessions (\(self.sessions.count))")
            await tearDownEverything()

            if let pendingRequest, pendingRequest.sequence <= sequence {
                self.pendingRequest = nil
            }
            if let activeRequest {
                if activeRequest.sequence > sequence {
                    // Submitted after `stopAll()` was called but applied before
                    // the stop ran: it must win.
                    if pendingRequest == nil { pendingRequest = activeRequest }
                    enqueueApply()
                }
                self.activeRequest = nil
            }

            publishSessions()
            continuation.resume()

        case let .unload(groupKey, token):
            await unloadIdlePlayback(groupKey: groupKey, token: token)

        case let .playbackFailed(groupKey):
            await handlePlaybackFailure(groupKey: groupKey)

        case let .barrier(continuation):
            continuation.resume()
        }
    }

    // MARK: - Reconcile

    private func apply(_ request: SessionReconcileRequest) async {
        appliedReconcileCount += 1
        let signpost = Signpost.begin(Signpost.Name.reconcile)
        defer { Signpost.end(Signpost.Name.reconcile, signpost) }
        Log.session.debug(
            "reconcile #\(self.appliedReconcileCount) reason=\(request.reason, privacy: .public) displays=\(request.displays.count) sessions=\(self.sessions.count)"
        )

        let desired = reconciliationPolicy.desiredSessions(
            displays: request.displays,
            assets: request.assets,
            placements: request.placements
        ).filter { playbackEvaluator.effectiveProfile(for: $0.asset).tier != .unsupported }

        let desiredByDisplay = Dictionary(
            desired.map { ($0.display.displayUUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 1. Remove sessions whose display is gone or whose asset changed.
        for displayID in Array(sessions.keys) {
            guard let runtime = sessions[displayID] else { continue }
            if desiredByDisplay[displayID]?.asset.id != runtime.asset.id {
                removeSession(displayID)
            }
        }

        // 2. Create missing sessions, refresh existing ones.
        for item in desired {
            let displayID = item.display.displayUUID

            if let runtime = sessions[displayID] {
                runtime.asset = item.asset
                runtime.placement = item.placement
                runtime.session.displayTarget = item.display
                runtime.surface.update(displayTarget: item.display)
                runtime.surface.setContentMode(item.placement.contentMode)

                if runtime.posterPath != item.asset.posterImageRelativePath {
                    runtime.posterPath = item.asset.posterImageRelativePath
                    runtime.surface.setPoster(await environment.loadPoster(relativePath: runtime.posterPath))
                }
            } else {
                let poster = await environment.loadPoster(relativePath: item.asset.posterImageRelativePath)
                let surface = environment.makeSurface(for: item.display)
                surface.setContentMode(item.placement.contentMode)
                surface.setPoster(poster)
                surface.showPoster()
                surface.onOcclusionChange = { [weak self] in
                    self?.reevaluate(reason: "window_occlusion_changed")
                }

                sessions[displayID] = SessionRuntime(
                    session: RenderSession(
                        id: UUID(),
                        displayTarget: item.display,
                        assetID: item.asset.id,
                        windowState: .visible,
                        playbackState: .idle,
                        energyMode: .suspend,
                        startedAt: .now,
                        lastVisibilityChange: .now
                    ),
                    asset: item.asset,
                    placement: item.placement,
                    surface: surface
                )
            }
        }

        // 3. Refresh per-session environment from a single window snapshot.
        // When nobody can see the desktop the window list cannot change the
        // outcome, so it is not even queried.
        let snapshot = request.runtimeState.isInvisibleToUser
            ? WindowListSnapshot(windows: [])
            : Signpost.interval(Signpost.Name.windowListQuery) {
                environment.captureWindowSnapshot()
            }
        let fullscreenDisplayUUIDs = fullscreenDetector.fullscreenDisplayUUIDs(
            displays: request.displays,
            snapshot: snapshot
        )
        if !request.runtimeState.isInvisibleToUser, fullscreenDisplayUUIDs != lastFullscreenDisplayUUIDs {
            lastFullscreenDisplayUUIDs = fullscreenDisplayUUIDs
            onFullscreenDisplaysChanged?(fullscreenDisplayUUIDs)
        }

        for (displayID, runtime) in sessions {
            if request.runtimeState.isInvisibleToUser {
                // Keep the last known window state: a locked screen must not
                // flip windows between hidden and shown.
                continue
            }
            runtime.isFullscreen = fullscreenDisplayUUIDs.contains(displayID)
            runtime.isOccluded = runtime.surface.isOccluded
                || occlusionDetector.isDisplayCovered(runtime.session.displayTarget, snapshot: snapshot)
        }

        // 4. Rebuild playback groups.
        var membership: [String: [SessionRuntime]] = [:]
        for runtime in sessions.values {
            membership[groupKey(for: runtime), default: []].append(runtime)
        }

        for key in Array(groups.keys) where membership[key] == nil {
            await tearDownGroup(key)
        }

        for key in membership.keys.sorted() {
            guard let members = membership[key], let first = members.first else { continue }
            let group = groups[key] ?? {
                let created = PlaybackGroup(key: key, asset: first.asset, engine: environment.makeEngine())
                let continuation = commandContinuation
                created.engine.onPlaybackFailure = {
                    continuation.yield(.playbackFailed(groupKey: key))
                }
                groups[key] = created
                return created
            }()

            let renditionChanged = group.asset.optimizedPlayback != first.asset.optimizedPlayback
            group.asset = first.asset
            if renditionChanged {
                group.optimizedUnavailable = false
                group.prepareFailed = false
                if group.isPrepared {
                    await switchRendition(of: group)
                }
            }

            await applyPolicy(to: group, members: members, request: request)
        }

        publishSessions()
    }

    private func applyPolicy(
        to group: PlaybackGroup,
        members: [SessionRuntime],
        request: SessionReconcileRequest
    ) async {
        for member in members {
            let decision = energyPolicy.decision(
                for: systemContext(for: member, group: group, request: request),
                preferences: request.preferences
            )
            if decision.mode != member.mode || decision.reason != member.modeReason {
                Log.energy.info(
                    "display \(member.session.displayTarget.displayUUID, privacy: .public): \(member.mode.rawValue, privacy: .public) -> \(decision.mode.rawValue, privacy: .public) reason=\(decision.reason.rawValue, privacy: .public) trigger=\(request.reason, privacy: .public)"
                )
            }
            member.mode = decision.mode
            member.modeReason = decision.reason
        }

        let wantsPlayback = members.contains { $0.mode == .animate }

        if wantsPlayback {
            cancelUnload(for: group)

            if !group.isPrepared && !group.prepareFailed {
                for member in members where member.mode == .animate {
                    member.session.playbackState = .preparing
                }
                publishSessions()
                await prepare(group, members: members)
            }
        }

        for member in members {
            if group.isPrepared {
                if !member.isAttached {
                    group.engine.attach(member.surface)
                    member.isAttached = true
                }
                group.engine.setLive(member.mode == .animate, for: member.surface)
                member.surface.showVideo()
            } else {
                member.surface.showPoster()
            }
        }

        let shouldPlay = wantsPlayback && group.isPrepared
        if group.isPlaying != shouldPlay {
            group.engine.setPlaying(shouldPlay)
            group.isPlaying = shouldPlay
            Log.playback.info(
                "asset \(group.asset.id.uuidString, privacy: .public): decoding \(shouldPlay ? "started" : "stopped", privacy: .public) surfaces=\(members.count)"
            )
        }

        if group.isPrepared && !wantsPlayback {
            scheduleUnloadIfNeeded(for: group, members: members, request: request)
        }

        for member in members {
            updateSessionState(of: member, group: group)
        }
    }

    private func updateSessionState(of member: SessionRuntime, group: PlaybackGroup) {
        let windowState: RenderSession.WindowState

        switch member.mode {
        case .animate:
            if group.isPrepared {
                member.session.playbackState = .animating
                member.session.energyMode = .animate
            } else {
                member.session.playbackState = .failed
                member.session.energyMode = .poster
            }
            windowState = .visible
        case .poster:
            member.session.playbackState = .poster
            member.session.energyMode = .poster
            windowState = .visible
        case .suspend:
            member.session.playbackState = group.isPrepared ? .paused : .idle
            member.session.energyMode = .suspend
            windowState = member.isFullscreen ? .hidden : .suspended
        }

        member.session.playbackSource = group.source
        member.session.modeReason = member.modeReason
        if group.source == .original || group.asset.optimizedPlayback == nil {
            member.session.videoPixelSize = group.asset.pixelSize
            member.session.videoFrameRate = group.asset.frameRate
            member.session.videoCodec = group.asset.codecType
        } else if let optimized = group.asset.optimizedPlayback {
            member.session.videoPixelSize = optimized.pixelSize
            member.session.videoFrameRate = optimized.frameRate
            member.session.videoCodec = optimized.codecType
        }

        if windowState == .hidden {
            member.surface.hide()
        } else {
            member.surface.show()
        }

        if member.session.windowState != windowState {
            member.session.windowState = windowState
            member.session.lastVisibilityChange = .now
        }
    }

    // MARK: - Playback lifecycle

    private func prepare(_ group: PlaybackGroup, members: [SessionRuntime]) async {
        let signpost = Signpost.begin(Signpost.Name.preparePlayback)
        defer {
            Signpost.end(Signpost.Name.preparePlayback, signpost)
            Log.playback.info(
                "asset \(group.asset.id.uuidString, privacy: .public): prepared=\(group.isPrepared) source=\(group.source?.rawValue ?? "none", privacy: .public)"
            )
        }

        if !group.optimizedUnavailable, let optimizedURL = environment.optimizedPlaybackURL(for: group.asset) {
            do {
                try await group.engine.prepare(url: optimizedURL, maximumPixelSize: nil, startTime: group.resumeTime)
                group.isPrepared = true
                group.source = .optimized
                return
            } catch {
                group.optimizedUnavailable = true
                Log.playback.error(
                    "asset \(group.asset.id.uuidString, privacy: .public): optimized rendition failed, falling back to original: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let bookmarkID = group.asset.originalBookmarkID
        let authorizedURL: URL
        do {
            authorizedURL = try await permissionStore.resolveBookmark(id: bookmarkID)
        } catch {
            group.prepareFailed = true
            Log.playback.error(
                "asset \(group.asset.id.uuidString, privacy: .public): original file is not accessible: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // The scope is held from here; every exit below either keeps it
        // recorded on the group or releases it.
        group.scopedBookmarkID = bookmarkID

        do {
            try await group.engine.prepare(
                url: authorizedURL,
                maximumPixelSize: Self.largestPixelSize(of: members),
                startTime: group.resumeTime
            )
            group.isPrepared = true
            group.source = .original
        } catch {
            await releaseScope(of: group)
            group.prepareFailed = true
            Log.playback.error(
                "asset \(group.asset.id.uuidString, privacy: .public): original file failed to play: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A new optimized rendition was produced while the asset is on screen:
    /// switch to it without interrupting playback. The engine only swaps once
    /// the new file is ready, and keeps playing the old one if it is not.
    private func switchRendition(of group: PlaybackGroup) async {
        guard let optimizedURL = environment.optimizedPlaybackURL(for: group.asset) else { return }

        do {
            try await group.engine.prepare(
                url: optimizedURL,
                maximumPixelSize: nil,
                startTime: group.engine.currentTime
            )
            group.source = .optimized
            // If the original file was being played, its scope is no longer needed.
            await releaseScope(of: group)
            Log.playback.info("asset \(group.asset.id.uuidString, privacy: .public): switched to new rendition")
        } catch {
            group.optimizedUnavailable = true
            Log.playback.error(
                "asset \(group.asset.id.uuidString, privacy: .public): new rendition failed, keeping current playback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Playback broke after it had started (for example the file went away).
    private func handlePlaybackFailure(groupKey: String) async {
        guard let group = groups[groupKey], group.isPrepared else { return }
        let failedSource = group.source
        Log.playback.error(
            "asset \(group.asset.id.uuidString, privacy: .public): playback failed on source \(failedSource?.rawValue ?? "none", privacy: .public)"
        )

        for member in sessions.values where self.groupKey(for: member) == groupKey {
            member.surface.showPoster()
            if member.isAttached {
                group.engine.detach(member.surface)
                member.isAttached = false
            }
        }
        await releasePlayback(of: group)

        if failedSource == .optimized {
            // Next reconcile falls back to the original file.
            group.optimizedUnavailable = true
        } else {
            group.prepareFailed = true
        }
        enqueueApply()
    }

    private func releaseScope(of group: PlaybackGroup) async {
        guard let bookmarkID = group.scopedBookmarkID else { return }
        group.scopedBookmarkID = nil
        await permissionStore.stopAccess(for: bookmarkID)
    }

    private func releasePlayback(of group: PlaybackGroup) async {
        cancelUnload(for: group)
        group.engine.teardown()
        group.isPrepared = false
        group.isPlaying = false
        group.source = nil
        await releaseScope(of: group)
    }

    private func tearDownGroup(_ key: String) async {
        guard let group = groups.removeValue(forKey: key) else { return }
        await releasePlayback(of: group)
    }

    private func removeSession(_ displayID: String) {
        guard let runtime = sessions.removeValue(forKey: displayID) else { return }
        if runtime.isAttached, let group = groups[groupKey(for: runtime)] {
            group.engine.detach(runtime.surface)
        }
        runtime.surface.onOcclusionChange = nil
        runtime.surface.close()
    }

    private func tearDownEverything() async {
        for displayID in Array(sessions.keys) {
            removeSession(displayID)
        }
        for key in Array(groups.keys) {
            await tearDownGroup(key)
        }
    }

    // MARK: - Deferred unload

    private func scheduleUnloadIfNeeded(
        for group: PlaybackGroup,
        members: [SessionRuntime],
        request: SessionReconcileRequest
    ) {
        let gracePeriods = members.compactMap { member in
            energyPolicy.playbackUnloadGracePeriod(
                for: member.mode,
                context: systemContext(for: member, group: group, request: request),
                preferences: request.preferences
            )
        }

        // Unload only when no member needs the pipeline kept warm.
        guard gracePeriods.count == members.count, let gracePeriod = gracePeriods.max() else {
            cancelUnload(for: group)
            return
        }

        // Already counting down: periodic re-evaluations must not restart it.
        guard group.unloadTask == nil else { return }

        group.unloadToken += 1
        let token = group.unloadToken
        let key = group.key
        let continuation = commandContinuation
        let sleep = self.sleep

        group.unloadTask = Task {
            await sleep(gracePeriod)
            guard !Task.isCancelled else { return }
            continuation.yield(.unload(groupKey: key, token: token))
        }
    }

    private func cancelUnload(for group: PlaybackGroup) {
        group.unloadTask?.cancel()
        group.unloadTask = nil
        group.unloadToken += 1
    }

    private func unloadIdlePlayback(groupKey: String, token: Int) async {
        guard let group = groups[groupKey], group.unloadToken == token else { return }
        group.unloadTask = nil
        guard group.isPrepared, !group.isPlaying else { return }

        let members = sessions.values.filter { self.groupKey(for: $0) == groupKey }

        // Keep the frame the user was looking at, and resume from it later.
        group.resumeTime = group.engine.currentTime
        let frozenFrame = await group.engine.snapshotCurrentFrame()

        for member in members {
            if let frozenFrame {
                member.surface.setPoster(frozenFrame)
            }
            member.surface.showPoster()
            if member.isAttached {
                group.engine.detach(member.surface)
                member.isAttached = false
            }
        }

        await releasePlayback(of: group)
        Log.playback.info("asset \(group.asset.id.uuidString, privacy: .public): idle player unloaded")

        for member in members {
            updateSessionState(of: member, group: group)
        }
        publishSessions()
    }

    // MARK: - Helpers

    private func publishSessions() {
        onSessionsChanged?(currentSessions)
    }

    /// Sessions showing the same asset share one playback engine: the video
    /// is decoded once however many displays show it.
    private func groupKey(for runtime: SessionRuntime) -> String {
        runtime.asset.id.uuidString
    }

    private static func largestPixelSize(of members: [SessionRuntime]) -> CGSize? {
        members
            .map { member -> CGSize in
                let target = member.session.displayTarget
                return CGSize(
                    width: target.frame.width * target.backingScaleFactor,
                    height: target.frame.height * target.backingScaleFactor
                )
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func systemContext(
        for runtime: SessionRuntime,
        group: PlaybackGroup,
        request: SessionReconcileRequest
    ) -> SystemContext {
        SystemContext(
            onBattery: request.runtimeState.powerSource == .battery,
            lowPowerMode: request.runtimeState.lowPowerMode,
            thermalState: request.runtimeState.thermalState,
            isOccluded: runtime.isOccluded,
            isFullscreen: runtime.isFullscreen,
            assetIsHeavy: effectivePlaybackIsHeavy(for: group),
            isPrimaryDisplay: runtime.session.displayTarget.isPrimary,
            activeDisplayCount: request.displays.count,
            isSystemSleeping: request.runtimeState.sleepState == .sleeping,
            isScreenLocked: request.runtimeState.isScreenLocked,
            displaysAsleep: request.runtimeState.displaysAsleep,
            isScreenSaverActive: request.runtimeState.isScreenSaverActive,
            isSessionInactive: request.runtimeState.isSessionInactive,
            isUserPaused: request.runtimeState.isUserPaused,
            reduceMotionEnabled: request.runtimeState.reduceMotionEnabled
        )
    }

    private func effectivePlaybackIsHeavy(for group: PlaybackGroup) -> Bool {
        if group.source == .original || group.optimizedUnavailable {
            return group.asset.eligibility.isHeavy
        }
        return playbackEvaluator.effectiveProfile(for: group.asset).isHeavy
    }
}
