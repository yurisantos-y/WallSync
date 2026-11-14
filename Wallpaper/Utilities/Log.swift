import Foundation
import os

/// Unified logging, one category per area. Read with:
/// `log stream --predicate 'subsystem == "com.yurisantos.wallpaper"' --level debug`
///
/// User file paths are never logged publicly; assets are identified by UUID.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.yurisantos.wallpaper"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let energy = Logger(subsystem: subsystem, category: "energy")
    static let importing = Logger(subsystem: subsystem, category: "import")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
}

/// Signposts for Instruments (os_signpost instrument, subsystem above,
/// category "performance").
enum Signpost {
    static let signposter = OSSignposter(subsystem: Log.subsystem, category: "performance")

    enum Name {
        static let reconcile: StaticString = "Reconcile"
        static let preparePlayback: StaticString = "PreparePlayback"
        static let decoding: StaticString = "Decoding"
        static let transcode: StaticString = "Transcode"
        static let posterGeneration: StaticString = "PosterGeneration"
        static let windowListQuery: StaticString = "WindowListQuery"
    }

    /// Measures a synchronous block.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
