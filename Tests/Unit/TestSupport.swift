import AVFoundation
import CoreGraphics
import XCTest
@testable import WallSync

// MARK: - Fixtures

enum Fixture {
    static func display(
        _ uuid: String = "display-1",
        id: UInt32 = 1,
        isPrimary: Bool = true,
        size: CGSize = CGSize(width: 1920, height: 1080)
    ) -> DisplayTarget {
        DisplayTarget(
            displayUUID: uuid,
            cgDisplayID: id,
            localizedName: "Display \(uuid)",
            frame: CGRect(origin: CGPoint(x: CGFloat(id - 1) * size.width, y: 0), size: size),
            backingScaleFactor: 2,
            isPrimary: isPrimary,
            maximumFramesPerSecond: 60,
            hasSeparateSpaceContext: true
        )
    }

    static func asset(
        id: UUID = UUID(),
        optimized: Bool = true,
        eligibility: PlaybackProfile = .safeDefault,
        posterPath: String? = nil
    ) -> WallpaperAsset {
        WallpaperAsset(
            id: id,
            displayName: "Loop \(id.uuidString.prefix(4))",
            originalBookmarkID: UUID(),
            originalPathHint: "/tmp/\(id.uuidString).mp4",
            containerType: "mp4",
            codecType: "HEVC",
            pixelSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            estimatedBitRate: 8_000_000,
            duration: 12,
            optimizedPlayback: optimized
                ? OptimizedPlaybackAsset(
                    relativePath: "OptimizedVideos/\(id.uuidString).mp4",
                    codecType: "HEVC",
                    pixelSize: CGSize(width: 1920, height: 1080),
                    frameRate: 30,
                    estimatedBitRate: 6_000_000,
                    duration: 12
                )
                : nil,
            hasAudio: false,
            posterImageRelativePath: posterPath,
            eligibility: eligibility,
            importedAt: .now
        )
    }

    static func request(
        displays: [DisplayTarget],
        assets: [WallpaperAsset],
        placements: [WallpaperPlacement]? = nil,
        preferences: UserPreferences = .defaultValue,
        configure: (inout AppRuntimeState) -> Void = { _ in }
    ) -> SessionReconcileRequest {
        var state = AppRuntimeState.initial
        state.powerSource = .ac
        state.lowPowerMode = false
        state.thermalState = .nominal
        state.activeDisplays = displays
        configure(&state)

        return SessionReconcileRequest(
            displays: displays,
            assets: assets,
            placements: placements ?? assets.prefix(1).map { WallpaperPlacement(assetID: $0.id, scope: .allDisplays) },
            preferences: preferences,
            runtimeState: state
        )
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Gate

/// Lets a test hold an async operation open and release it later.
@MainActor
final class AsyncGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    init(open: Bool = false) {
        isOpen = open
    }

    func pass() async {
        enteredCount += 1
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilEntered() async {
        guard enteredCount == 0 else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
}

// MARK: - Test doubles

@MainActor
final class FakeSurface: WallpaperSurface {
    private(set) var displayTarget: DisplayTarget
    var isOccluded = false
    var onOcclusionChange: (() -> Void)?

    private(set) var isClosed = false
    private(set) var isWindowShown = false
    private(set) var isShowingVideo = false
    private(set) var posterSetCount = 0
    private(set) var contentMode: WallpaperPlacement.ContentMode = .aspectFill

    init(displayTarget: DisplayTarget) {
        self.displayTarget = displayTarget
    }

    func simulateOcclusion(_ occluded: Bool) {
        isOccluded = occluded
        onOcclusionChange?()
    }

    func update(displayTarget: DisplayTarget) { self.displayTarget = displayTarget }
    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode) { self.contentMode = contentMode }
    func setPoster(_ image: CGImage?) { posterSetCount += 1 }
    private(set) var transitionImages: [CGImage?] = []
    private(set) var fadeDurations: [TimeInterval] = []
    func setTransitionImage(_ image: CGImage?) { transitionImages.append(image) }
    func fadeOutTransitionImage(duration: TimeInterval) { fadeDurations.append(duration) }
    private(set) var cropHistory: [CGRect?] = []
    var crop: CGRect? { cropHistory.last ?? nil }
    func setContentCrop(_ crop: CGRect?) { cropHistory.append(crop) }
    private(set) var dimmingHistory: [DimOverlay?] = []
    var dimming: DimOverlay? { dimmingHistory.last ?? nil }
    func setDimming(_ overlay: DimOverlay?) { dimmingHistory.append(overlay) }
    func showPoster() { isShowingVideo = false }
    func showVideo() { isShowingVideo = true }
    func show() { isWindowShown = true }
    func hide() { isWindowShown = false }
    func close() { isClosed = true; isWindowShown = false }
}

@MainActor
final class FakeEngine: SharedPlaybackEngine {
    unowned let environment: FakeEnvironment
    private(set) var preparedURL: URL?
    private(set) var prepareAttempts: [URL] = []
    private(set) var startTimes: [TimeInterval] = []
    private(set) var maximumPixelSizes: [CGSize?] = []
    private(set) var isPlaying = false
    private(set) var teardownCount = 0
    private(set) var playbackRates: [Double] = []
    private(set) var attached: [ObjectIdentifier: Bool] = [:]
    var currentTime: TimeInterval = 0
    var onPlaybackFailure: (() -> Void)?

    init(environment: FakeEnvironment) {
        self.environment = environment
    }

    var isLoaded: Bool { preparedURL != nil }
    var attachedCount: Int { attached.count }
    var liveCount: Int { attached.values.filter { $0 }.count }

    func prepare(url: URL, maximumPixelSize: CGSize?, startTime: TimeInterval) async throws {
        environment.events.append("prepare")
        prepareAttempts.append(url)
        startTimes.append(startTime)
        maximumPixelSizes.append(maximumPixelSize)
        await environment.prepareGate.pass()
        if environment.failingURLs.contains(url) {
            throw AVPlayerPlaybackError.assetNotPlayable
        }
        preparedURL = url
    }

    func attach(_ surface: any WallpaperSurface) { attached[ObjectIdentifier(surface)] = true }
    func detach(_ surface: any WallpaperSurface) { attached[ObjectIdentifier(surface)] = nil }
    func setLive(_ isLive: Bool, for surface: any WallpaperSurface) { attached[ObjectIdentifier(surface)] = isLive }
    func setPlaying(_ isPlaying: Bool) { self.isPlaying = isPlaying }
    func setPlaybackRate(_ rate: Double) { playbackRates.append(rate) }
    func snapshotCurrentFrame() async -> CGImage? {
        snapshotCount += 1
        return environment.snapshotImage
    }
    private(set) var snapshotCount = 0

    func teardown() {
        if preparedURL != nil { environment.events.append("teardown") }
        teardownCount += 1
        preparedURL = nil
        isPlaying = false
    }
}

@MainActor
final class FakeEnvironment: SessionEnvironment {
    private(set) var surfaces: [FakeSurface] = []
    private(set) var engines: [FakeEngine] = []
    var failingURLs: Set<URL> = []
    /// What engines return as their current frame.
    var snapshotImage: CGImage?
    /// Order in which engines were torn down and prepared, for tests that
    /// care about decoders overlapping.
    var events: [String] = []
    var prepareGate = AsyncGate(open: true)
    var windowSnapshot = WindowListSnapshot(windows: [])
    private(set) var windowSnapshotCaptureCount = 0

    func makeSurface(for display: DisplayTarget) -> any WallpaperSurface {
        let surface = FakeSurface(displayTarget: display)
        surfaces.append(surface)
        return surface
    }

    func makeEngine() -> any SharedPlaybackEngine {
        let engine = FakeEngine(environment: self)
        engines.append(engine)
        return engine
    }

    func loadPoster(relativePath: String?) async -> CGImage? { nil }

    func optimizedPlaybackURL(for asset: WallpaperAsset) -> URL? {
        asset.optimizedPlayback.map { URL(fileURLWithPath: "/optimized/\($0.relativePath)") }
    }

    func captureWindowSnapshot() -> WindowListSnapshot {
        windowSnapshotCaptureCount += 1
        return windowSnapshot
    }

    static func optimizedURL(for asset: WallpaperAsset) -> URL {
        URL(fileURLWithPath: "/optimized/\(asset.optimizedPlayback!.relativePath)")
    }

    var openSurfaces: [FakeSurface] { surfaces.filter { !$0.isClosed } }
    var loadedEngines: [FakeEngine] { engines.filter(\.isLoaded) }

    func surface(for displayUUID: String) -> FakeSurface? {
        openSurfaces.last { $0.displayTarget.displayUUID == displayUUID }
    }
}

actor FakePermissionStore: PermissionStoring {
    private(set) var resolveCount = 0
    private(set) var stopCount = 0
    private(set) var removedBookmarks: [UUID] = []
    private var failResolve = false

    var activeScopes: Int { resolveCount - stopCount }

    func setFailResolve(_ value: Bool) { failResolve = value }

    static func originalURL(for id: UUID) -> URL {
        URL(fileURLWithPath: "/original/\(id.uuidString).mov")
    }

    func createBookmark(for url: URL) throws -> AccessBookmark {
        AccessBookmark(id: UUID(), bookmarkData: Data(), createdAt: .now, lastResolvedAt: nil, isStale: false, originalPathHint: url.path)
    }

    func storeBookmark(_ bookmark: AccessBookmark) throws {}
    func bookmark(for id: UUID) -> AccessBookmark? { nil }

    func resolveBookmark(id: UUID) throws -> URL {
        if failResolve { throw PermissionError.bookmarkNotFound }
        resolveCount += 1
        return Self.originalURL(for: id)
    }

    func stopAccess(for id: UUID) { stopCount += 1 }
    func removeBookmark(id: UUID) throws { removedBookmarks.append(id) }
}

// MARK: - Synthetic video

enum SyntheticVideo {
    enum Failure: Error { case writerFailed, pixelBufferFailed }

    /// Writes a short H.264 clip with moving content, optionally with a
    /// silent AAC track, entirely in memory-generated frames.
    static func write(
        to url: URL,
        size: CGSize = CGSize(width: 640, height: 360),
        frameRate: Int32 = 30,
        frameCount: Int = 45,
        includeAudio: Bool = false,
        codec: AVVideoCodecType = .h264
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ]
            )
            writer.add(audio)
            audioInput = audio
        }

        guard writer.startWriting() else { throw writer.error ?? Failure.writerFailed }
        writer.startSession(atSourceTime: .zero)

        // Audio goes first and is finished at once; otherwise the writer's
        // interleaving stops accepting video while it waits for audio.
        if let audioInput {
            let duration = Double(frameCount) / Double(frameRate)
            try appendSilence(to: audioInput, duration: duration)
            audioInput.markAsFinished()
        }

        for index in 0..<frameCount {
            let buffer = try pixelBuffer(size: size, shade: UInt8(40 + (index * 4) % 200))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate))
        }
        input.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.writerFailed }
    }

    private static func pixelBuffer(size: CGSize, shade: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { throw Failure.pixelBufferFailed }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private static func appendSilence(to input: AVAssetWriterInput, duration: Double) throws {
        let sampleRate = 44_100.0
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { throw Failure.writerFailed }

        let frames = Int(duration * sampleRate)
        let byteCount = frames * 2
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { throw Failure.writerFailed }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw Failure.writerFailed }

        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard input.append(sampleBuffer) else { throw Failure.writerFailed }
    }
}
