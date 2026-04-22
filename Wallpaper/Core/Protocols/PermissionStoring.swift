import Foundation

protocol PermissionStoring: Actor {
    func createBookmark(for url: URL) throws -> AccessBookmark
    func storeBookmark(_ bookmark: AccessBookmark) throws
    func bookmark(for id: UUID) -> AccessBookmark?
    func resolveBookmark(id: UUID) throws -> URL
    func stopAccess(for id: UUID)
}
