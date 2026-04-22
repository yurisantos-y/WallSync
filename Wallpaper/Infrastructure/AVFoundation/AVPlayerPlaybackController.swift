import AppKit
import AVFoundation
import Foundation

@MainActor
final class AVPlayerPlaybackController: PlaybackControlling {
    private var posterImage: NSImage?
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var preparedURL: URL?
    private weak var hostView: WallpaperHostView?

    init(posterImage: NSImage?) {
        self.posterImage = posterImage
    }

    func prepare(with url: URL) async throws {
        if preparedURL == url, queuePlayer != nil {
            return
        }

        teardown()

        let asset = AVURLAsset(url: url)
        async let playableTask = asset.load(.isPlayable)
        async let durationTask = asset.load(.duration)
        let playable = try await playableTask
        guard playable else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }
        _ = try await durationTask

        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = false
        }

        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none

        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        preparedURL = url
    }

    func attach(to hostView: WallpaperHostView, contentMode: WallpaperPlacement.ContentMode) {
        self.hostView = hostView
        hostView.attach(player: queuePlayer, poster: posterImage, contentMode: contentMode)
    }

    func setPosterImage(_ image: NSImage?) {
        posterImage = image
        hostView?.updatePoster(image)
    }

    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) {
        hostView?.setContentMode(contentMode)
    }

    func play() {
        hostView?.showVideoLayer()
        queuePlayer?.playImmediately(atRate: 1.0)
    }

    func pause() {
        queuePlayer?.pause()
    }

    func showPoster() {
        queuePlayer?.pause()
        hostView?.showPosterLayer()
    }

    func teardown() {
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        looper = nil
        queuePlayer = nil
        preparedURL = nil
        hostView?.detachPlayer()
    }
}

enum AVPlayerPlaybackError: LocalizedError {
    case assetNotPlayable

    var errorDescription: String? {
        switch self {
        case .assetNotPlayable:
            return "O video nao esta em um estado reproduzivel."
        }
    }
}
