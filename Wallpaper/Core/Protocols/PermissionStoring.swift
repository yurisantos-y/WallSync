import Foundation

protocol PermissionStoring: Actor {
    func createBookmark(for url: URL) throws -> AccessBookmark
    func storeBookmark(_ bookmark: AccessBookmark) throws
    func bookmark(for id: UUID) -> AccessBookmark?
    /// Starts a security scope for the bookmark. Every successful call must be
    /// balanced by exactly one `stopAccess(for:)`.
    func resolveBookmark(id: UUID) throws -> URL
    func stopAccess(for id: UUID)
    func removeBookmark(id: UUID) throws
}
