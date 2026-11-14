import Foundation

actor FilePermissionStore: PermissionStoring {
    private let fileURL: URL
    private var bookmarks: [UUID: AccessBookmark] = [:]
    private var activeScopeCounts: [UUID: Int] = [:]
    private var activeURLs: [UUID: URL] = [:]
    private var loaded = false
    private var loadIssue: StorageIssue?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the bookmark file and reports whether it had to be reset.
    func load() -> StorageIssue? {
        loadIfNeeded()
        return loadIssue
    }

    /// Number of security scopes currently held, for diagnostics and tests.
    var activeScopeCount: Int {
        activeScopeCounts.values.reduce(0, +)
    }

    func createBookmark(for url: URL) throws -> AccessBookmark {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return AccessBookmark(
            id: UUID(),
            bookmarkData: bookmarkData,
            createdAt: .now,
            lastResolvedAt: nil,
            isStale: false,
            originalPathHint: url.path
        )
    }

    func storeBookmark(_ bookmark: AccessBookmark) throws {
        loadIfNeeded()
        bookmarks[bookmark.id] = bookmark
        try persist()
    }

    func bookmark(for id: UUID) -> AccessBookmark? {
        loadIfNeeded()
        return bookmarks[id]
    }

    func resolveBookmark(id: UUID) throws -> URL {
        loadIfNeeded()

        guard var bookmark = bookmarks[id] else {
            throw PermissionError.bookmarkNotFound
        }

        if let activeURL = activeURLs[id] {
            activeScopeCounts[id, default: 0] += 1
            bookmark.lastResolvedAt = .now
            bookmarks[id] = bookmark
            return activeURL
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            throw PermissionError.cannotAccessScopedResource
        }

        // From here on the scope is held; nothing below may throw, otherwise
        // the caller would never know it has to call `stopAccess`.
        activeURLs[id] = url
        activeScopeCounts[id] = 1
        bookmark.lastResolvedAt = .now

        if isStale {
            if let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmark.bookmarkData = refreshed
                bookmark.isStale = false
            } else {
                bookmark.isStale = true
            }
        }

        bookmarks[id] = bookmark
        if isStale {
            try? persist()
        }

        return url
    }

    func stopAccess(for id: UUID) {
        guard let count = activeScopeCounts[id] else { return }
        if count > 1 {
            activeScopeCounts[id] = count - 1
            return
        }

        activeScopeCounts[id] = nil
        if let url = activeURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func removeBookmark(id: UUID) throws {
        loadIfNeeded()
        releaseAllScopes(for: id)
        guard bookmarks.removeValue(forKey: id) != nil else { return }
        try persist()
    }

    /// Drops bookmarks that no asset references any more.
    @discardableResult
    func pruneBookmarks(keeping ids: Set<UUID>) throws -> Int {
        loadIfNeeded()
        let stale = bookmarks.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return 0 }
        for id in stale {
            releaseAllScopes(for: id)
            bookmarks[id] = nil
        }
        try persist()
        return stale.count
    }

    private func releaseAllScopes(for id: UUID) {
        activeScopeCounts[id] = nil
        if let url = activeURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let result = JSONFile.load([UUID: AccessBookmark].self, from: fileURL, defaultValue: [:])
        bookmarks = result.value
        loadIssue = result.issue
    }

    private func persist() throws {
        try JSONFile.save(bookmarks, to: fileURL)
    }
}

enum PermissionError: LocalizedError {
    case bookmarkNotFound
    case cannotAccessScopedResource

    var errorDescription: String? {
        switch self {
        case .bookmarkNotFound:
            return String(localized: "The saved permission for this video was not found.")
        case .cannotAccessScopedResource:
            return String(localized: "WallSync could not access the authorized file.")
        }
    }
}
