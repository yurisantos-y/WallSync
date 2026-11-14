import AppKit
import AVFoundation
import Foundation

/// Plays one video in a gapless loop through `AVQueuePlayer` + `AVPlayerLooper`.
///
/// The player item is built from a composition that contains only the video
/// track, so no audio is ever decoded — neither for optimized renditions nor
/// for the fallback to the user's original file.
@MainActor
final class AVPlayerPlaybackEngine: SharedPlaybackEngine {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loopDuration: CMTime = .zero
    private var surfaces: [ObjectIdentifier: DesktopWallpaperWindowController] = [:]
    private var preparationID = 0

    var currentTime: TimeInterval {
        guard let player, loopDuration.seconds > 0 else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return seconds.truncatingRemainder(dividingBy: loopDuration.seconds)
    }

    func prepare(url: URL, maximumPixelSize: CGSize?, startTime: TimeInterval) async throws {
        releasePlayer()
        preparationID += 1
        let currentPreparation = preparationID

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }

        let timeRange = try await sourceTrack.load(.timeRange)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        guard timeRange.duration.seconds > 0 else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }

        // Video-only composition: the audio tracks of the source never reach
        // the player, so they cannot be decoded.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }
        try track.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        track.preferredTransform = preferredTransform

        let item = AVPlayerItem(asset: composition)
        if let maximumPixelSize {
            // Never decode more pixels than the largest display can show.
            item.preferredMaximumResolution = maximumPixelSize
        }

        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance

        let looper = AVPlayerLooper(player: player, templateItem: item)
        try await Self.waitUntilReady(looper)

        guard currentPreparation == preparationID else {
            player.removeAllItems()
            throw CancellationError()
        }

        if startTime > 0, startTime < timeRange.duration.seconds {
            await player.seek(
                to: CMTime(seconds: startTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        self.player = player
        self.looper = looper
        self.loopDuration = timeRange.duration

        for surface in surfaces.values {
            surface.hostView.setPlayer(player)
        }
    }

    func attach(_ surface: any WallpaperSurface) {
        guard let controller = surface as? DesktopWallpaperWindowController else { return }
        surfaces[ObjectIdentifier(controller)] = controller
        controller.hostView.setPlayer(player)
    }

    func detach(_ surface: any WallpaperSurface) {
        guard let controller = surface as? DesktopWallpaperWindowController else { return }
        surfaces[ObjectIdentifier(controller)] = nil
        controller.hostView.setPlayer(nil)
    }

    func setLive(_ isLive: Bool, for surface: any WallpaperSurface) {}

    func setPlaying(_ isPlaying: Bool) {
        guard let player else { return }
        if isPlaying {
            player.playImmediately(atRate: 1.0)
        } else {
            player.pause()
        }
    }

    func snapshotCurrentFrame() async -> CGImage? {
        guard let asset = player?.currentItem?.asset, let time = player?.currentTime(), time.isValid else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: time).image
    }

    func teardown() {
        preparationID += 1
        releasePlayer()
    }

    private func releasePlayer() {
        for surface in surfaces.values {
            surface.hostView.setPlayer(nil)
        }
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
        loopDuration = .zero
    }

    private static func waitUntilReady(_ looper: AVPlayerLooper) async throws {
        let statuses = AsyncStream<AVPlayerLooper.Status> { continuation in
            let observation = looper.observe(\.status, options: [.initial, .new]) { looper, _ in
                continuation.yield(looper.status)
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                observation.invalidate()
                timeout.cancel()
            }
        }

        for await status in statuses {
            switch status {
            case .ready:
                return
            case .failed, .cancelled:
                throw looper.error ?? AVPlayerPlaybackError.assetNotPlayable
            default:
                continue
            }
        }

        throw AVPlayerPlaybackError.preparationTimedOut
    }
}

enum AVPlayerPlaybackError: LocalizedError {
    case assetNotPlayable
    case preparationTimedOut

    var errorDescription: String? {
        switch self {
        case .assetNotPlayable:
            return String(localized: "The video cannot be played.")
        case .preparationTimedOut:
            return String(localized: "The video took too long to start playing.")
        }
    }
}
