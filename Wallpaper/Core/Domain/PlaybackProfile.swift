import Foundation

struct PlaybackProfile: Codable, Hashable, Sendable {
    enum Tier: String, Codable, CaseIterable, Sendable {
        case safe
        case warning
        case unsupported
    }

    enum RecommendedMode: String, Codable, CaseIterable, Sendable {
        case animate
        case posterOnly
        case unsupported
    }

    var tier: Tier
    var hardwareDecodeLikely: Bool
    var reasonCodes: [String]
    var isHeavy: Bool
    var recommendedMode: RecommendedMode

    static let safeDefault = PlaybackProfile(
        tier: .safe,
        hardwareDecodeLikely: true,
        reasonCodes: [],
        isHeavy: false,
        recommendedMode: .animate
    )
}
