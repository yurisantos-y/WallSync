import Foundation

/// An ordered set of wallpapers and the rule that picks one of them.
///
/// The active item is always derived from the clock and this configuration
/// (see `PlaylistSchedule`); nothing here counts or advances.
struct WallpaperPlaylist: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A new wallpaper every `intervalSeconds`.
        case interval
        /// A wallpaper for each part of the day.
        case timeOfDay
        /// One wallpaper for light appearance and another for dark.
        case appearance

        var id: String { rawValue }
    }

    struct TimeSlot: Codable, Identifiable, Hashable, Sendable {
        var id: UUID = UUID()
        /// Minutes after midnight, local time, at which the slot begins.
        var startMinute: Int
        var assetID: UUID?
    }

    let id: UUID
    var name: String
    var kind: Kind = .interval

    // Interval playlists.
    var assetIDs: [UUID] = []
    var intervalSeconds: TimeInterval = 30 * 60
    var isShuffled: Bool = false
    /// Recorded so that a shuffled order is the same after a relaunch.
    var seed: UInt64 = UInt64.random(in: .min ... .max)
    /// The instant step zero began.
    var anchor: Date = Date(timeIntervalSinceReferenceDate: 0)
    /// Steps added by "Next wallpaper".
    var manualOffset: Int = 0

    // Time-of-day playlists.
    var slots: [TimeSlot] = []

    // Appearance playlists.
    var lightAssetID: UUID? = nil
    var darkAssetID: UUID? = nil

    static let minimumInterval: TimeInterval = 60

    /// Every asset the playlist can show.
    var referencedAssetIDs: [UUID] {
        switch kind {
        case .interval: return assetIDs
        case .timeOfDay: return slots.compactMap(\.assetID)
        case .appearance: return [lightAssetID, darkAssetID].compactMap { $0 }
        }
    }

    /// Whether the active item depends on the clock.
    var isTimeDriven: Bool { kind == .interval || kind == .timeOfDay }

    mutating func removeAsset(_ assetID: UUID) {
        assetIDs.removeAll { $0 == assetID }
        for index in slots.indices where slots[index].assetID == assetID {
            slots[index].assetID = nil
        }
        if lightAssetID == assetID { lightAssetID = nil }
        if darkAssetID == assetID { darkAssetID = nil }
    }
}

extension WallpaperPlaylist {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            kind: (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .interval,
            assetIDs: try container.decodeIfPresent([UUID].self, forKey: .assetIDs) ?? [],
            intervalSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds) ?? 30 * 60,
            isShuffled: try container.decodeIfPresent(Bool.self, forKey: .isShuffled) ?? false,
            seed: try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0,
            anchor: try container.decodeIfPresent(Date.self, forKey: .anchor) ?? Date(timeIntervalSinceReferenceDate: 0),
            manualOffset: try container.decodeIfPresent(Int.self, forKey: .manualOffset) ?? 0,
            slots: try container.decodeIfPresent([TimeSlot].self, forKey: .slots) ?? [],
            lightAssetID: try container.decodeIfPresent(UUID.self, forKey: .lightAssetID),
            darkAssetID: try container.decodeIfPresent(UUID.self, forKey: .darkAssetID)
        )
    }
}

/// A temporary instruction from a Focus filter. It never changes what the
/// user assigned: when it goes away the previous state is simply recomputed.
enum FocusOverride: Codable, Hashable, Sendable {
    case pause
    case asset(UUID)
    case playlist(UUID)
}
