import AVFoundation
import Foundation
import Observation

/// State of the editor sheet. Everything it creates — the player, the
/// real-time preview composition, the access to the original file — lives
/// only while the sheet is open and is released by `close()`.
@MainActor
@Observable
final class AssetEditorModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// The original file cannot be reached, so nothing can be edited.
        case unavailable
    }

    let asset: WallpaperAsset
    private(set) var phase = Phase.loading
    private(set) var duration: TimeInterval

    var selectionStart: TimeInterval
    var selectionEnd: TimeInterval
    var crossfade: TimeInterval

    /// Areas covered by a logo, unit rectangles with a top-left origin.
    var regions: [CGRect]
    /// The visible part of the picture when the logo is cut off instead.
    var crop: CGRect?
    /// A frame of the original, to mark regions on.
    private(set) var stillImage: CGImage?
    private(set) var isAnalyzing = false
    private(set) var analysisProgress = 0.0
    private(set) var logoNote: String?
    /// Before / after stills of the current regions.
    private(set) var comparison: [WatermarkPreviewer.Pair] = []
    private(set) var comparisonStrategies: [WatermarkStrategy] = []
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    private(set) var isSuggesting = false
    private(set) var suggestionProgress = 0.0
    /// Result of the last "Suggest", shown under the button.
    private(set) var suggestionNote: String?

    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var sourceAsset: AVURLAsset?
    @ObservationIgnored private(set) var sourceURL: URL?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private var hasAccess = false

    static let minimumSelection: TimeInterval = 0.5

    init(asset: WallpaperAsset) {
        self.asset = asset
        duration = asset.duration
        let recipe = asset.editRecipe.normalized(duration: asset.duration)
        selectionStart = recipe.trim?.start ?? 0
        selectionEnd = recipe.trim?.end ?? asset.duration
        crossfade = recipe.loopCrossfade
        regions = recipe.watermarkRegions
        crop = recipe.crop
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// The edits as they would be stored. Parts of the recipe this editor
    /// does not show are carried over unchanged.
    var recipe: EditRecipe {
        var recipe = asset.editRecipe
        recipe.trim = EditRecipe.Trim(start: selectionStart, end: selectionEnd)
        recipe.loopCrossfade = crossfade
        recipe.watermarkRegions = regions
        recipe.crop = crop
        return recipe.normalized(duration: duration)
    }

    var resultDuration: TimeInterval {
        recipe.timing(duration: duration).outputDuration
    }

    var maximumCrossfade: TimeInterval {
        min(EditRecipe.maximumCrossfade, (selectionEnd - selectionStart) / 2)
    }

    var hasChanges: Bool {
        recipe != asset.editRecipe.normalized(duration: duration)
    }

    // MARK: - Lifecycle

    func open(coordinator: AppCoordinator) async {
        self.coordinator = coordinator
        guard let url = await coordinator.beginEditing(asset) else {
            phase = .unavailable
            return
        }
        hasAccess = true
        sourceURL = url
        let source = AVURLAsset(url: url)
        sourceAsset = source
        if duration <= 0, let loaded = try? await source.load(.duration).seconds, loaded > 0 {
            duration = loaded
            selectionEnd = loaded
        }
        phase = .ready
        rebuildPreview(fromSeam: false)
        await loadStillImage()
    }

    private func loadStillImage() async {
        guard let sourceAsset else { return }
        let generator = AVAssetImageGenerator(asset: sourceAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        let time = CMTime(seconds: (selectionStart + selectionEnd) / 2, preferredTimescale: 600)
        stillImage = try? await generator.image(at: time).image
    }

    func close() {
        previewTask?.cancel()
        suggestTask?.cancel()
        analysisTask?.cancel()
        comparison = []
        stillImage = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        sourceAsset = nil

        if hasAccess, let coordinator {
            hasAccess = false
            let asset = asset
            Task { await coordinator.endEditing(asset) }
        }
    }

    // MARK: - Editing

    func setStart(_ value: TimeInterval) {
        selectionStart = min(max(0, value), selectionEnd - Self.minimumSelection)
        crossfade = min(crossfade, maximumCrossfade)
        scrub(to: selectionStart)
    }

    func setEnd(_ value: TimeInterval) {
        selectionEnd = max(min(duration, value), selectionStart + Self.minimumSelection)
        crossfade = min(crossfade, maximumCrossfade)
        scrub(to: max(selectionStart, selectionEnd - 1.0 / 30))
    }

    func setCrossfade(_ value: TimeInterval) {
        crossfade = min(max(0, value), maximumCrossfade)
    }

    // MARK: - Logo removal

    /// Cutting the logo off instead of filling it in, when that costs
    /// little of the picture.
    var reframeOffer: WatermarkPlanner.Reframe? {
        crop == nil ? WatermarkPlanner.reframe(excluding: regions) : nil
    }

    func addRegion(_ region: CGRect) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = region.standardized.intersection(unit)
        guard !clipped.isNull, clipped.width > 0.005, clipped.height > 0.005 else { return }
        regions.append(clipped)
        comparison = []
    }

    func removeRegion(at index: Int) {
        guard regions.indices.contains(index) else { return }
        regions.remove(at: index)
        comparison = []
    }

    /// Reframes so the marked logos fall outside the picture; nothing is
    /// left to fill in.
    func acceptReframe() {
        guard let offer = reframeOffer else { return }
        crop = offer.crop
        regions = []
        comparison = []
        logoNote = nil
    }

    func clearReframe() {
        crop = nil
        comparison = []
    }

    func detectLogos() {
        guard phase == .ready, let sourceURL, !isAnalyzing else { return }
        isAnalyzing = true
        analysisProgress = 0
        logoNote = nil

        analysisTask = Task { [weak self] in
            let found = try? await Task.detached(priority: .userInitiated) {
                try await WatermarkPreviewer.detect(url: sourceURL) { fraction in
                    Task { @MainActor in self?.analysisProgress = fraction }
                }
            }.value

            guard let self else { return }
            self.isAnalyzing = false
            guard !Task.isCancelled else { return }
            if let found, !found.isEmpty {
                self.regions = found
                self.comparison = []
                self.logoNote = String(localized: "Check the suggested areas, and adjust or remove them if needed.")
            } else {
                self.logoNote = String(localized: "No fixed logo was found. Draw a rectangle over it.")
            }
        }
    }

    /// Renders before / after stills at three moments of the selection.
    func compare() {
        guard phase == .ready, let sourceURL, !isAnalyzing, !regions.isEmpty else { return }
        isAnalyzing = true
        analysisProgress = 0
        let regions = regions, crop = crop
        let span = selectionEnd - selectionStart
        let times = [0.2, 0.5, 0.8].map { selectionStart + span * $0 }

        analysisTask = Task { [weak self] in
            let result = try? await Task.detached(priority: .userInitiated) {
                try await WatermarkPreviewer.render(url: sourceURL, regions: regions, crop: crop, times: times) { fraction in
                    Task { @MainActor in self?.analysisProgress = fraction }
                }
            }.value

            guard let self else { return }
            self.isAnalyzing = false
            guard !Task.isCancelled else { return }
            if let result, !result.pairs.isEmpty {
                self.comparison = result.pairs
                self.comparisonStrategies = result.strategies
                self.logoNote = nil
            } else {
                self.logoNote = String(localized: "The comparison could not be made.")
            }
        }
    }

    func clearComparison() {
        comparison = []
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        isAnalyzing = false
    }

    func reset() {
        regions = []
        crop = nil
        comparison = []
        logoNote = nil
        selectionStart = 0
        selectionEnd = duration
        crossfade = 0
        suggestionNote = nil
        rebuildPreview(fromSeam: false)
    }

    /// Shows the original frame at `time` while a handle is dragged.
    private func scrub(to time: TimeInterval) {
        guard phase == .ready, let sourceAsset else { return }
        if !isScrubbing {
            isScrubbing = true
            previewTask?.cancel()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            player.insert(AVPlayerItem(asset: sourceAsset), after: nil)
            player.pause()
        }
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Plays the edited loop; with `fromSeam`, starts shortly before its end
    /// so the join is the first thing seen.
    func rebuildPreview(fromSeam: Bool) {
        guard phase == .ready, let sourceAsset else { return }
        isScrubbing = false
        previewTask?.cancel()
        let recipe = recipe

        previewTask = Task { [weak self] in
            guard let preview = try? await LoopPreviewBuilder.make(asset: sourceAsset, recipe: recipe),
                  let self, !Task.isCancelled else { return }

            let item = AVPlayerItem(asset: preview.composition)
            item.videoComposition = preview.videoComposition
            self.looper?.disableLooping()
            self.player.removeAllItems()
            self.looper = AVPlayerLooper(player: self.player, templateItem: item)

            if fromSeam {
                let lead = max(0, preview.duration - recipe.loopCrossfade - 1.5)
                await self.player.seek(
                    to: CMTime(seconds: lead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            guard !Task.isCancelled else { return }
            self.player.play()
        }
    }

    // MARK: - Suggestion

    func suggest() {
        guard phase == .ready, let sourceURL, !isSuggesting else { return }
        isSuggesting = true
        suggestionProgress = 0
        suggestionNote = nil

        suggestTask = Task { [weak self] in
            let result = try? await Task.detached(priority: .userInitiated) {
                try await LoopPointAnalyzer.suggest(url: sourceURL) { fraction in
                    Task { @MainActor in self?.suggestionProgress = fraction }
                }
            }.value

            guard let self else { return }
            self.isSuggesting = false
            guard !Task.isCancelled else { return }

            guard let suggestion = result ?? nil else {
                self.suggestionNote = String(localized: "No good loop points were found. Adjust them by hand.")
                return
            }
            self.selectionStart = suggestion.start
            self.selectionEnd = min(suggestion.end, self.duration)
            self.crossfade = min(suggestion.crossfade, self.maximumCrossfade)
            self.suggestionNote = suggestion.crossfade > 0
                ? String(localized: "Closest match found. A short crossfade hides the remaining difference.")
                : String(localized: "The start and end match: no crossfade is needed.")
            self.rebuildPreview(fromSeam: true)
        }
    }

    func cancelSuggestion() {
        suggestTask?.cancel()
        isSuggesting = false
    }
}
