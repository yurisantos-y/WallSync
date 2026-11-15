import AppKit
import AVFoundation
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Decodes one video once and shows it on every attached display.
///
/// ## Why this design (section 3.2 of the audit)
///
/// *One decode per video.* A single `AVQueuePlayer` + `AVPlayerLooper` plays a
/// gapless loop. With one display attached the player renders straight into
/// that window's `AVPlayerLayer`, which is the cheapest path the system
/// offers. With two or more displays the same player feeds an
/// `AVPlayerItemVideoOutput`; each decoded frame is an IOSurface-backed pixel
/// buffer in the decoder's native biplanar YUV format, and every window's
/// layer points at that same IOSurface. Nothing is copied to the CPU and
/// nothing is decoded twice.
///
/// *Sync.* All displays show the output of the same decoder, so they are
/// frame-identical by construction: there is no clock to drift.
///
/// *Rejected alternatives.* (a) One `AVPlayer` per display driven by a shared
/// clock with `setRate(_:time:atHostTime:)`: N decodes for N displays and
/// periodic drift correction. (b) `AVSampleBufferDisplayLayer` per display
/// under an `AVSampleBufferRenderSynchronizer`: each layer decodes its own
/// copy of the compressed samples, so it also costs N decodes unless the app
/// runs its own `VTDecompressionSession`, reordering and loop timeline —
/// much more code for the same result as `AVPlayerItemVideoOutput`.
/// (c) Several `AVPlayerLayer`s on one player: only one of them is
/// guaranteed to display.
///
/// *No audio.* The player item is a composition containing only the video
/// track, so audio is never decoded, for optimized renditions and original
/// files alike.
@MainActor
final class AVPlayerPlaybackEngine: SharedPlaybackEngine {
    private struct Sink {
        let host: any VideoFrameHosting
        var isLive: Bool
    }

    private struct ItemOutput {
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loopDuration: CMTime = .zero
    private var nominalFrameRate: Float = 30
    private var colorDescription = VideoColorDescription.sdr
    private var preparationID = 0

    private var sinkOrder: [ObjectIdentifier] = []
    private var sinks: [ObjectIdentifier: Sink] = [:]
    /// The sink whose `AVPlayerLayer` currently shows the player.
    private var directSinkID: ObjectIdentifier?

    private var itemOutputs: [ObjectIdentifier: ItemOutput] = [:]
    private var lastPixelBuffer: CVPixelBuffer?
    private var displayLink: CADisplayLink?
    private var displayLinkSinkID: ObjectIdentifier?
    private let displayLinkTarget = DisplayLinkTarget()

    private var wantsPlaying = false
    private var decodingSignpost: OSSignpostIntervalState?
    private var failureObserver: NSObjectProtocol?

    var onPlaybackFailure: (() -> Void)?

    /// Frames pushed to the mirrored layers; exposed for tests and diagnostics.
    private(set) var presentedFrameCount = 0
    /// The asset handed to the player; exposed so tests can prove it has no audio.
    private(set) var loadedAsset: AVAsset?

    init() {
        displayLinkTarget.engine = self
    }

    private var isMirroring: Bool { sinks.count >= 2 }

    var currentTime: TimeInterval {
        guard let player, loopDuration.seconds > 0 else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return seconds.truncatingRemainder(dividingBy: loopDuration.seconds)
    }

    // MARK: - Loading

    func prepare(url: URL, maximumPixelSize: CGSize?, startTime: TimeInterval) async throws {
        preparationID += 1
        let currentPreparation = preparationID

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }

        let (timeRange, preferredTransform, frameRate, formats) = try await sourceTrack.load(
            .timeRange, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )
        guard timeRange.duration.seconds > 0 else {
            throw AVPlayerPlaybackError.assetNotPlayable
        }

        // Video-only composition: the source's audio tracks never reach the
        // player, so they cannot be decoded.
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

        let newPlayer = AVQueuePlayer()
        newPlayer.isMuted = true
        newPlayer.allowsExternalPlayback = false
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.actionAtItemEnd = .advance

        let newLooper = AVPlayerLooper(player: newPlayer, templateItem: item)
        try await Self.waitUntilReady(newLooper)

        if startTime > 0, startTime < timeRange.duration.seconds {
            await newPlayer.seek(
                to: CMTime(seconds: startTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        // Replacing a running player: hold the frame on screen so the switch
        // to the new source shows no gap.
        if player != nil, !sinks.isEmpty, let frozen = await snapshotCurrentFrame() {
            for sink in sinks.values {
                sink.host.hostView.setFrozenFrame(frozen)
            }
        }

        guard currentPreparation == preparationID else {
            newLooper.disableLooping()
            newPlayer.removeAllItems()
            throw CancellationError()
        }

        releasePlayer()

        player = newPlayer
        looper = newLooper
        loadedAsset = composition
        loopDuration = timeRange.duration
        nominalFrameRate = frameRate > 0 ? frameRate : 30
        colorDescription = formats.first.map(VideoFormatInspector.colorDescription(of:)) ?? .sdr
        observeFailures(of: newPlayer)

        configurePresentation()
        applyPlayState()
    }

    func teardown() {
        preparationID += 1
        wantsPlaying = false
        releasePlayer()
        for sink in sinks.values {
            sink.host.hostView.setFrozenFrame(nil)
        }
    }

    private func releasePlayer() {
        endDecodingInterval()
        stopDisplayLink()
        removeOutputs()

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil

        for sink in sinks.values {
            sink.host.hostView.setPlayer(nil)
        }
        directSinkID = nil

        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
        loadedAsset = nil
        lastPixelBuffer = nil
        loopDuration = .zero
    }

    // MARK: - Surfaces

    func attach(_ surface: any WallpaperSurface) {
        guard let host = surface as? any VideoFrameHosting else { return }
        let id = ObjectIdentifier(host)
        guard sinks[id] == nil else { return }
        sinks[id] = Sink(host: host, isLive: true)
        sinkOrder.append(id)
        configurePresentation()
    }

    func detach(_ surface: any WallpaperSurface) {
        guard let host = surface as? any VideoFrameHosting else { return }
        let id = ObjectIdentifier(host)
        guard sinks.removeValue(forKey: id) != nil else { return }
        sinkOrder.removeAll { $0 == id }

        host.hostView.setPlayer(nil)
        host.hostView.setFrozenFrame(nil)
        if directSinkID == id { directSinkID = nil }
        if displayLinkSinkID == id { stopDisplayLink() }
        configurePresentation()
    }

    func setLive(_ isLive: Bool, for surface: any WallpaperSurface) {
        guard let host = surface as? any VideoFrameHosting else { return }
        let id = ObjectIdentifier(host)
        guard sinks[id] != nil, sinks[id]?.isLive != isLive else { return }
        sinks[id]?.isLive = isLive
        updateDisplayLink()
    }

    func setPlaying(_ isPlaying: Bool) {
        wantsPlaying = isPlaying
        applyPlayState()
    }

    /// Chooses between the direct `AVPlayerLayer` path (one display) and the
    /// shared-frame path (several displays).
    private func configurePresentation() {
        for sink in sinks.values {
            sink.host.hostView.setWantsExtendedDynamicRange(colorDescription.isHDR)
        }

        guard let player else { return }

        if isMirroring {
            attachOutputs(to: player)
            // A sink that was showing the player directly keeps doing so until
            // the first shared frame arrives (see `pumpFrame`), so the switch
            // is invisible.
        } else {
            removeOutputs()
            if let onlyID = sinkOrder.first, let only = sinks[onlyID] {
                only.host.hostView.setPlayer(player)
                directSinkID = onlyID
            }
        }

        updateDisplayLink()
    }

    private func applyPlayState() {
        guard let player else { return }

        if wantsPlaying {
            player.playImmediately(atRate: 1.0)
            if decodingSignpost == nil {
                decodingSignpost = Signpost.begin(Signpost.Name.decoding)
            }
        } else {
            player.pause()
            endDecodingInterval()
        }

        updateDisplayLink()
    }

    private func endDecodingInterval() {
        if let decodingSignpost {
            Signpost.end(Signpost.Name.decoding, decodingSignpost)
        }
        decodingSignpost = nil
    }

    // MARK: - Shared frames

    private func attachOutputs(to player: AVQueuePlayer) {
        var items = player.items()
        items.append(contentsOf: looper?.loopingPlayerItems ?? [])
        for item in items {
            _ = output(for: item)
        }
    }

    private func output(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        let id = ObjectIdentifier(item)
        if let existing = itemOutputs[id] {
            return existing.output
        }

        // The decoder's native biplanar YUV format, IOSurface-backed: frames
        // go from the hardware decoder to Core Animation without conversion
        // or CPU copies, and 10-bit sources stay 10-bit.
        let pixelFormat = colorDescription.isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        itemOutputs[id] = ItemOutput(item: item, output: output)
        return output
    }

    private func removeOutputs() {
        for entry in itemOutputs.values {
            entry.item.remove(entry.output)
        }
        itemOutputs.removeAll()
    }

    /// Pulls the frame due at `hostTime` and shows it on every live display.
    /// Driven by the display link; callable directly from tests.
    func pumpFrame(hostTime: CFTimeInterval) {
        guard isMirroring, let item = player?.currentItem else { return }

        let output = output(for: item)
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }

        lastPixelBuffer = pixelBuffer
        presentedFrameCount += 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, sink) in sinks where sink.isLive || id == directSinkID {
            sink.host.hostView.presentFrame(surface)
        }
        CATransaction.commit()

        // Shared frames are flowing: retire the direct player layer.
        if let directSinkID {
            sinks[directSinkID]?.host.hostView.setPlayer(nil)
            self.directSinkID = nil
        }
    }

    private func updateDisplayLink() {
        let liveSinkID = sinkOrder.first { sinks[$0]?.isLive == true }
        guard wantsPlaying, player != nil, isMirroring, let liveSinkID, let sink = sinks[liveSinkID] else {
            stopDisplayLink()
            return
        }

        // The link belongs to a display that is actually showing video; a
        // link tied to a hidden window would be suspended by the system.
        guard displayLinkSinkID != liveSinkID || displayLink == nil else { return }
        stopDisplayLink()

        let link = sink.host.hostView.displayLink(
            target: displayLinkTarget,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        // Wake at the video's frame rate, not at the display's refresh rate.
        let rate = max(1, nominalFrameRate.rounded(.up))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkSinkID = liveSinkID
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkSinkID = nil
    }

    // MARK: - Snapshot

    func snapshotCurrentFrame() async -> CGImage? {
        if isMirroring, let lastPixelBuffer {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(lastPixelBuffer, options: nil, imageOut: &image)
            if let image { return image }
        }

        guard let loadedAsset, loopDuration.seconds > 0 else { return nil }

        // The composition is never mutated after it is handed to the player,
        // so reading it from the image generator's queue is safe.
        return await Self.frame(
            of: UncheckedSendableBox(loadedAsset),
            at: CMTime(seconds: currentTime, preferredTimescale: 600)
        )
    }

    private nonisolated static func frame(of asset: UncheckedSendableBox<AVAsset>, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset.value)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: time).image
    }

    // MARK: - Failure handling

    private func observeFailures(of player: AVQueuePlayer) {
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak player] notification in
            let failedItem = notification.object as? AVPlayerItem
            let failedID = failedItem.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player, let failedID else { return }
                guard player.items().contains(where: { ObjectIdentifier($0) == failedID }) else { return }
                Log.playback.error("player item failed to play to end")
                self.onPlaybackFailure?()
            }
        }
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

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// `CADisplayLink` retains its target; this indirection keeps the engine free
/// of a retain cycle.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var engine: AVPlayerPlaybackEngine?

    @objc func tick(_ link: CADisplayLink) {
        engine?.pumpFrame(hostTime: link.targetTimestamp)
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
