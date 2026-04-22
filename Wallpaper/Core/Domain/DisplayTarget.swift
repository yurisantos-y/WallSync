import Foundation

struct DisplayTarget: Identifiable, Hashable, Sendable {
    var id: String { displayUUID }

    var displayUUID: String
    var cgDisplayID: UInt32
    var localizedName: String
    var frame: CGRect
    var backingScaleFactor: CGFloat
    var isPrimary: Bool
    var maximumFramesPerSecond: Int
    var hasSeparateSpaceContext: Bool
}
