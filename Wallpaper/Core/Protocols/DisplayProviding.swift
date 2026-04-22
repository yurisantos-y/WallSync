import Foundation

@MainActor
protocol DisplayProviding: AnyObject {
    func currentDisplays() -> [DisplayTarget]
}
