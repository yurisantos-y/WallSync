import Foundation

struct AccessBookmark: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var bookmarkData: Data
    var createdAt: Date
    var lastResolvedAt: Date?
    var isStale: Bool
    var originalPathHint: String
}
