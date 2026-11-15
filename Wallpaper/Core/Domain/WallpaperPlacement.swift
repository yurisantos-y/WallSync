import Foundation

struct WallpaperPlacement: Codable, Identifiable, Hashable, Sendable {
    enum ContentMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case aspectFill
        case aspectFit

        var id: String { rawValue }
    }

    enum Scope: Hashable, Sendable {
        case allDisplays
        case specificDisplay(String)
        case primaryOnly
    }

    let id: UUID
    var assetID: UUID
    var scope: Scope
    var contentMode: ContentMode
    var isEnabled: Bool
    /// When set, the wallpaper comes from this playlist and `assetID` is only
    /// the fallback used while the playlist has nothing to show.
    var playlistID: UUID?
    /// One video stretched across every display the placement applies to,
    /// each display showing its own slice.
    var spansDisplays: Bool
    /// Which part of the video stays visible when it is larger than the
    /// displays' bounding box: -1 … 1 on each axis, 0 is centred.
    var panoramaOffset: CGPoint

    init(
        id: UUID = UUID(),
        assetID: UUID,
        scope: Scope,
        contentMode: ContentMode = .aspectFill,
        isEnabled: Bool = true,
        playlistID: UUID? = nil,
        spansDisplays: Bool = false,
        panoramaOffset: CGPoint = .zero
    ) {
        self.id = id
        self.assetID = assetID
        self.scope = scope
        self.contentMode = contentMode
        self.isEnabled = isEnabled
        self.playlistID = playlistID
        self.spansDisplays = spansDisplays
        self.panoramaOffset = panoramaOffset
    }
}

extension WallpaperPlacement {
    /// Tolerant decoding: files written before playlists and panoramas keep
    /// loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            assetID: try container.decode(UUID.self, forKey: .assetID),
            scope: try container.decode(Scope.self, forKey: .scope),
            contentMode: (try? container.decodeIfPresent(ContentMode.self, forKey: .contentMode)) ?? .aspectFill,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            playlistID: try container.decodeIfPresent(UUID.self, forKey: .playlistID),
            spansDisplays: try container.decodeIfPresent(Bool.self, forKey: .spansDisplays) ?? false,
            panoramaOffset: try container.decodeIfPresent(CGPoint.self, forKey: .panoramaOffset) ?? .zero
        )
    }

    var isGlobal: Bool {
        if case .allDisplays = scope { return true }
        return false
    }

    func applies(toDisplayUUID displayUUID: String) -> Bool {
        if case let .specificDisplay(uuid) = scope { return uuid == displayUUID }
        return false
    }
}

extension WallpaperPlacement.Scope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case displayUUID
    }

    private enum Kind: String, Codable {
        case allDisplays
        case specificDisplay
        case primaryOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .allDisplays:
            self = .allDisplays
        case .specificDisplay:
            let displayUUID = try container.decode(String.self, forKey: .displayUUID)
            self = .specificDisplay(displayUUID)
        case .primaryOnly:
            self = .primaryOnly
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .allDisplays:
            try container.encode(Kind.allDisplays, forKey: .kind)
        case let .specificDisplay(displayUUID):
            try container.encode(Kind.specificDisplay, forKey: .kind)
            try container.encode(displayUUID, forKey: .displayUUID)
        case .primaryOnly:
            try container.encode(Kind.primaryOnly, forKey: .kind)
        }
    }
}
