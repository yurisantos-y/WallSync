import Foundation

/// Identifies the container from the file's leading bytes rather than from its
/// extension, so a renamed `.m4v` or `.mov` is classified by what it really is.
enum ContainerFormatDetector {
    static let requiredHeaderLength = 12

    static func containerType(header: Data, fallbackExtension: String) -> String {
        let fallback = fallbackExtension.lowercased()
        guard header.count >= requiredHeaderLength else { return fallback }

        let bytes = [UInt8](header.prefix(requiredHeaderLength))
        let boxType = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""

        switch boxType {
        case "ftyp":
            let majorBrand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            return majorBrand == "qt  " ? "mov" : "mp4"
        case "moov", "mdat", "wide", "free", "skip", "pnot":
            // Classic QuickTime files may start without an `ftyp` box.
            return "mov"
        default:
            return fallback
        }
    }
}
