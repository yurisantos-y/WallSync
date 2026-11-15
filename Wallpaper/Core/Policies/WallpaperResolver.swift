import Foundation

/// The single place that decides what every display shows right now.
///
/// Playlists, schedules, Focus filters, Shortcuts and the menu bar all want a
/// say. Instead of each of them changing sessions, they only change the state
/// passed in here, and the result feeds the session reconcile. Precedence,
/// highest first:
///
/// 1. Manual pause by the user.
/// 2. An active Focus filter.
/// 3. A playlist or schedule.
/// 4. The fixed wallpaper assigned to the display.
///
/// Pausing stops motion; the still that stays on screen is whatever the lower
/// layers pick. Temporary layers (pause, Focus) never write to the user's
/// assignments, so when they end the previous state comes back by itself:
/// the function is simply evaluated again without them.
enum WallpaperResolver {
    struct Input: Sendable {
        var displays: [DisplayTarget]
        /// The assignments the user saved.
        var placements: [WallpaperPlacement]
        var playlists: [WallpaperPlaylist] = []
        var assets: [WallpaperAsset]
        var focus: FocusOverride? = nil
        var isUserPaused: Bool = false
        var now: Date = .now
        var calendar: Calendar = .current
        var isDarkAppearance: Bool = false
        /// Items the playlists were showing when the desktop stopped being
        /// visible. While set, those playlists do not advance: nothing is
        /// switched or prepared for a desktop nobody can see.
        var heldPlaylistItems: [UUID: UUID]? = nil
    }

    enum Source: Hashable, Sendable {
        case fixed
        case playlist(UUID)
        case focus
    }

    enum PauseSource: Hashable, Sendable {
        case user
        case focus
    }

    struct DisplayContent: Hashable, Sendable {
        var displayUUID: String
        var assetID: UUID
        var source: Source
        /// The user's placement with the resolved asset, scoped to the display.
        var placement: WallpaperPlacement
    }

    struct Output: Equatable, Sendable {
        var displays: [DisplayContent] = []
        var pause: PauseSource? = nil
        /// The active item of every playlist that is in use.
        var playlistItems: [UUID: UUID] = [:]
        /// Earliest instant at which the clock changes the result.
        var nextChange: Date? = nil

        /// Per-display placements in the shape the session reconcile expects.
        var placements: [WallpaperPlacement] { displays.map(\.placement) }

        var activePlaylistIDs: Set<UUID> { Set(playlistItems.keys) }

        func content(forDisplayUUID displayUUID: String) -> DisplayContent? {
            displays.first { $0.displayUUID == displayUUID }
        }
    }

    static func resolve(_ input: Input) -> Output {
        var output = Output()
        if input.isUserPaused {
            output.pause = .user
        } else if input.focus == .pause {
            output.pause = .focus
        }

        let assetIDs = Set(input.assets.map(\.id))
        let usableAssetIDs = Set(input.assets.filter(\.isReadyForRotation).map(\.id))
        let playlistsByID = Dictionary(input.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let context = PlaylistSchedule.Context(
            now: input.now,
            calendar: input.calendar,
            isDarkAppearance: input.isDarkAppearance,
            usableAssetIDs: usableAssetIDs
        )

        var states: [UUID: PlaylistSchedule.State] = [:]
        func item(of playlistID: UUID) -> UUID? {
            guard let playlist = playlistsByID[playlistID] else { return nil }
            let state: PlaylistSchedule.State
            if let cached = states[playlistID] {
                state = cached
            } else {
                var computed = PlaylistSchedule.state(of: playlist, context: context)
                // A held item stays as long as it can still be shown.
                if let held = input.heldPlaylistItems?[playlistID],
                   usableAssetIDs.contains(held),
                   playlist.referencedAssetIDs.contains(held) {
                    computed.assetID = held
                }
                states[playlistID] = computed
                state = computed
            }
            return state.assetID
        }

        let policy = SessionReconciliationPolicy()
        let enabledPlacements = input.placements.filter(\.isEnabled)

        // What the Focus filter asks for, when it names something that exists.
        var focusContent: (assetID: UUID, playlistID: UUID?)?
        switch input.focus {
        case let .asset(assetID)? where assetIDs.contains(assetID):
            focusContent = (assetID, nil)
        case let .playlist(playlistID)?:
            if let assetID = item(of: playlistID) {
                focusContent = (assetID, playlistID)
            }
        default:
            break
        }

        for display in input.displays {
            let userPlacement = policy.resolvedPlacement(for: display, placements: enabledPlacements)
            var placement: WallpaperPlacement
            var source = Source.fixed

            if let userPlacement {
                placement = userPlacement
                // A playlist hidden behind a Focus filter is not evaluated, so
                // it cannot ask for a timer either.
                if focusContent == nil, let playlistID = userPlacement.playlistID, let assetID = item(of: playlistID) {
                    placement.assetID = assetID
                    source = .playlist(playlistID)
                }
            } else if let focusContent {
                placement = WallpaperPlacement(assetID: focusContent.assetID, scope: .allDisplays)
            } else {
                continue
            }

            if let focusContent {
                placement.assetID = focusContent.assetID
                source = .focus
            }

            guard assetIDs.contains(placement.assetID) else { continue }

            // Same identity as the user's placement, narrowed to this display.
            placement.scope = .specificDisplay(display.displayUUID)
            placement.isEnabled = true
            output.displays.append(
                DisplayContent(displayUUID: display.displayUUID, assetID: placement.assetID, source: source, placement: placement)
            )
        }

        for (playlistID, state) in states {
            guard let assetID = state.assetID else { continue }
            output.playlistItems[playlistID] = assetID
            if let nextChange = state.nextChange {
                output.nextChange = min(output.nextChange ?? nextChange, nextChange)
            }
        }

        return output
    }
}
