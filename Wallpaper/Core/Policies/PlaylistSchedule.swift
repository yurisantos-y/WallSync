import Foundation

/// The active item of a playlist as a pure function of the clock.
///
/// Because nothing is counted, the answer is right after sleep, a relaunch,
/// a clock change or a time-zone change with no special handling: whoever
/// asks just passes the current date.
enum PlaylistSchedule {
    struct Context: Sendable {
        var now: Date
        var calendar: Calendar = .current
        var isDarkAppearance: Bool = false
        /// Assets that exist and are optimized; the others are skipped.
        var usableAssetIDs: Set<UUID>
    }

    struct State: Equatable, Sendable {
        var assetID: UUID?
        /// When the active item changes next because of the clock. `nil`
        /// when the clock cannot change it.
        var nextChange: Date?
    }

    static func state(of playlist: WallpaperPlaylist, context: Context) -> State {
        switch playlist.kind {
        case .interval: return intervalState(of: playlist, context: context)
        case .timeOfDay: return timeOfDayState(of: playlist, context: context)
        case .appearance: return appearanceState(of: playlist, context: context)
        }
    }

    /// Convenience for callers that only need the item.
    static func activeItem(of playlist: WallpaperPlaylist, context: Context) -> UUID? {
        state(of: playlist, context: context).assetID
    }

    // MARK: - Interval

    private static func intervalState(of playlist: WallpaperPlaylist, context: Context) -> State {
        let items = playlist.assetIDs.filter(context.usableAssetIDs.contains)
        guard let first = items.first else { return State(assetID: nil, nextChange: nil) }
        guard items.count > 1 else { return State(assetID: first, nextChange: nil) }

        let interval = max(playlist.intervalSeconds, WallpaperPlaylist.minimumInterval)
        let elapsedSteps = Int((context.now.timeIntervalSince(playlist.anchor) / interval).rounded(.down))
        let step = elapsedSteps + playlist.manualOffset
        let index = playlist.isShuffled
            ? shuffledIndex(step: step, count: items.count, seed: playlist.seed)
            : floorMod(step, items.count)

        return State(
            assetID: items[index],
            nextChange: playlist.anchor.addingTimeInterval(Double(elapsedSteps + 1) * interval)
        )
    }

    /// Every pass through the list uses its own permutation, derived from the
    /// recorded seed, and never starts with the item the previous pass ended on.
    static func shuffledIndex(step: Int, count: Int, seed: UInt64) -> Int {
        guard count > 2 else { return floorMod(step, max(count, 1)) }
        let cycle = floorDiv(step, count)
        let position = floorMod(step, count)

        var order = permutation(count: count, seed: seed, cycle: cycle)
        let previousLast = permutation(count: count, seed: seed, cycle: cycle - 1)[count - 1]
        // Swapping the first two never changes a pass's last item, so the
        // rule needs no knowledge of earlier passes.
        if order[0] == previousLast {
            order.swapAt(0, 1)
        }
        return order[position]
    }

    private static func permutation(count: Int, seed: UInt64, cycle: Int) -> [Int] {
        var generator = SplitMix64(state: seed ^ (UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15))
        var order = Array(0..<count)
        for index in stride(from: count - 1, to: 0, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            order.swapAt(index, other)
        }
        return order
    }

    // MARK: - Time of day

    private static func timeOfDayState(of playlist: WallpaperPlaylist, context: Context) -> State {
        let slots = playlist.slots
            .filter { slot in slot.assetID.map(context.usableAssetIDs.contains) ?? false }
            .sorted { $0.startMinute < $1.startMinute }
        guard let last = slots.last else { return State(assetID: nil, nextChange: nil) }

        let components = context.calendar.dateComponents([.hour, .minute], from: context.now)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        // Before the first slot of the day, the last slot of yesterday is
        // still running.
        let active = slots.last { $0.startMinute <= minute } ?? last

        var nextChange: Date?
        if slots.count > 1 {
            nextChange = slots.compactMap { slot -> Date? in
                let start = min(max(slot.startMinute, 0), 24 * 60 - 1)
                return context.calendar.nextDate(
                    after: context.now,
                    matching: DateComponents(hour: start / 60, minute: start % 60, second: 0),
                    matchingPolicy: .nextTime
                )
            }.min()
        }

        return State(assetID: active.assetID, nextChange: nextChange)
    }

    // MARK: - Appearance

    private static func appearanceState(of playlist: WallpaperPlaylist, context: Context) -> State {
        let preferred = context.isDarkAppearance
            ? [playlist.darkAssetID, playlist.lightAssetID]
            : [playlist.lightAssetID, playlist.darkAssetID]
        let assetID = preferred.compactMap { $0 }.first(where: context.usableAssetIDs.contains)
        return State(assetID: assetID, nextChange: nil)
    }

    // MARK: - Arithmetic

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    private static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }
}

/// Small deterministic generator; the system generator cannot be seeded.
struct SplitMix64: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
