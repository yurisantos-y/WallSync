import Foundation

@MainActor
protocol PlaybackControlling: AnyObject {
    func prepare(with url: URL) async throws
    func play()
    func pause()
    func showPoster()
    func teardown()
}
