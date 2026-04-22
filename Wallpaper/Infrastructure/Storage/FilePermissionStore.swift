import Foundation

actor FilePermissionStore: PermissionStoring {
    private let fileURL: URL
    private var bookmarks: [UUID: AccessBookmark] = [:]
    private var activeScopeCounts: [UUID: Int] = [:]
    private var activeURLs: [UUID: URL] = [:]
    private var loaded = false

    init(fileManager: FileManager = .default) {
        let supportDirectory = try! fileManager.wallpaperApplicationSupportDirectory()
        self.fileURL = supportDirectory.appendingPathComponent("bookmarks.json")
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
        try loadIfNeeded()
        bookmarks[bookmark.id] = bookmark
        try persist()
    }

    func bookmark(for id: UUID) -> AccessBookmark? {
        try? loadIfNeeded()
        return bookmarks[id]
    }

    func resolveBookmark(id: UUID) throws -> URL {
        try loadIfNeeded()

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

        if isStale {
            bookmark.bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmark.isStale = false
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw PermissionError.cannotAccessScopedResource
        }

        bookmark.lastResolvedAt = .now
        bookmarks[id] = bookmark
        activeURLs[id] = url
        activeScopeCounts[id] = 1

        if isStale {
            try persist()
        }

        return url
    }

    func stopAccess(for id: UUID) {
        try? loadIfNeeded()

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

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            bookmarks = [:]
            return
        }

        let data = try Data(contentsOf: fileURL)
        bookmarks = try JSONDecoder().decode([UUID: AccessBookmark].self, from: data)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bookmarks)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum PermissionError: LocalizedError {
    case bookmarkNotFound
    case cannotAccessScopedResource

    var errorDescription: String? {
        switch self {
        case .bookmarkNotFound:
            return "O bookmark do video nao foi encontrado."
        case .cannotAccessScopedResource:
            return "O app nao conseguiu acessar o arquivo autorizado."
        }
    }
}
