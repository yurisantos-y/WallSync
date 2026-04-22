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

    init(
        id: UUID = UUID(),
        assetID: UUID,
        scope: Scope,
        contentMode: ContentMode = .aspectFill,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.scope = scope
        self.contentMode = contentMode
        self.isEnabled = isEnabled
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
