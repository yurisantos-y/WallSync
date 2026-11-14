import CoreGraphics
import Foundation

/// A desktop-level window on one display that can show a still poster or the
/// frames of a playback engine.
@MainActor
protocol WallpaperSurface: AnyObject {
    var displayTarget: DisplayTarget { get }
    /// Whether the window server reports the window as not visible. Coverage
    /// by other apps' windows is derived separately from the window snapshot.
    var isOccluded: Bool { get }
    var onOcclusionChange: (() -> Void)? { get set }

    func update(displayTarget: DisplayTarget)
    func setContentMode(_ contentMode: WallpaperPlacement.ContentMode)
    func setPoster(_ image: CGImage?)
    func showPoster()
    func showVideo()
    func show()
    func hide()
    func close()
}

/// Decodes one video and presents it on every attached surface.
@MainActor
protocol SharedPlaybackEngine: AnyObject {
    /// Position of the playhead inside the loop, in seconds.
    var currentTime: TimeInterval { get }

    func prepare(url: URL, maximumPixelSize: CGSize?, startTime: TimeInterval) async throws
    func attach(_ surface: any WallpaperSurface)
    func detach(_ surface: any WallpaperSurface)
    /// A surface that is not live keeps showing its last frame.
    func setLive(_ isLive: Bool, for surface: any WallpaperSurface)
    func setPlaying(_ isPlaying: Bool)
    func snapshotCurrentFrame() async -> CGImage?
    func teardown()
}

/// Everything the session manager needs from the outside world; replaced by
/// test doubles in unit tests.
@MainActor
protocol SessionEnvironment: AnyObject {
    func makeSurface(for display: DisplayTarget) -> any WallpaperSurface
    func makeEngine() -> any SharedPlaybackEngine
    func loadPoster(relativePath: String?) async -> CGImage?
    func optimizedPlaybackURL(for asset: WallpaperAsset) -> URL?
    /// Called once per reconcile; the result feeds every detector.
    func captureWindowSnapshot() -> WindowListSnapshot
}
