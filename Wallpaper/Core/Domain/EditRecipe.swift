import CoreGraphics
import Foundation

/// Non-destructive edits of a wallpaper. The original file is never modified:
/// the recipe is stored with the asset and the optimized rendition is the
/// result of applying it to the original. Everything in here is paid for once,
/// by the optimizer, and costs nothing during playback.
struct EditRecipe: Codable, Hashable, Sendable {
    struct Trim: Codable, Hashable, Sendable {
        /// Seconds from the start of the original video.
        var start: TimeInterval
        var end: TimeInterval
    }

    /// The part of the original that is kept. `nil` keeps everything.
    var trim: Trim? = nil
    /// Seconds over which the end of the loop dissolves into its beginning.
    var loopCrossfade: TimeInterval = 0
    /// Areas covered by a logo or stamp, in unit coordinates of the upright
    /// video with the origin at the top-left corner.
    var watermarkRegions: [CGRect] = []
    /// Visible part of the picture, in the same unit coordinates. Used to
    /// push a mark near an edge out of the frame. `nil` keeps the full frame.
    var crop: CGRect? = nil

    static let empty = EditRecipe()
    static let maximumCrossfade: TimeInterval = 3

    var isEmpty: Bool {
        trim == nil && loopCrossfade <= 0 && watermarkRegions.isEmpty && crop == nil
    }

    /// Edits that change pixels and therefore always need a re-encode.
    var changesPixels: Bool {
        loopCrossfade > 0 || !watermarkRegions.isEmpty || crop != nil
    }
}

extension EditRecipe {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            trim: try container.decodeIfPresent(Trim.self, forKey: .trim),
            loopCrossfade: try container.decodeIfPresent(TimeInterval.self, forKey: .loopCrossfade) ?? 0,
            watermarkRegions: try container.decodeIfPresent([CGRect].self, forKey: .watermarkRegions) ?? [],
            crop: try container.decodeIfPresent(CGRect.self, forKey: .crop)
        )
    }

    /// The recipe with every value brought into a range the optimizer can
    /// apply to a video of `duration` seconds.
    func normalized(duration: TimeInterval) -> EditRecipe {
        var result = self
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

        if let trim, duration > 0 {
            let start = min(max(0, trim.start), duration)
            let end = min(max(start, trim.end), duration)
            // A selection shorter than a few frames is not a loop.
            if end - start < 0.2 || (start <= 0.001 && end >= duration - 0.001) {
                result.trim = nil
            } else {
                result.trim = Trim(start: start, end: end)
            }
        } else {
            result.trim = nil
        }

        let length = result.trim.map { $0.end - $0.start } ?? duration
        // The dissolve consumes its own length; keep at least half of the clip.
        result.loopCrossfade = max(0, min(loopCrossfade, Self.maximumCrossfade, length / 2))
        if result.loopCrossfade < 0.02 { result.loopCrossfade = 0 }

        result.watermarkRegions = watermarkRegions
            .map { $0.standardized.intersection(unit) }
            .filter { !$0.isNull && $0.width > 0.001 && $0.height > 0.001 }

        if let crop {
            let clipped = crop.standardized.intersection(unit)
            let keepsEverything = clipped.width >= 0.999 && clipped.height >= 0.999
            result.crop = (clipped.isNull || clipped.width < 0.1 || clipped.height < 0.1 || keepsEverything) ? nil : clipped
        }

        return result
    }

    /// Time range of the original that is read, and the resulting duration.
    func timing(duration: TimeInterval) -> (start: TimeInterval, end: TimeInterval, crossfade: TimeInterval, outputDuration: TimeInterval) {
        let recipe = normalized(duration: duration)
        let start = recipe.trim?.start ?? 0
        let end = recipe.trim?.end ?? duration
        return (start, end, recipe.loopCrossfade, (end - start) - recipe.loopCrossfade)
    }
}
