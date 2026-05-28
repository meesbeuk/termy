import Foundation

/// Gate for the "Show Image" affordance. SwiftTerm renders inline images
/// natively from the iTerm2 (OSC 1337) and kitty graphics protocols when a
/// program emits them (imgcat / viu / chafa / kitty +kitten icat), and Termy
/// can also render a user-picked image straight into the terminal stream via
/// SwiftTerm's createImage API. This policy decides which local files are safe
/// to render — kept pure so the size cap + format allow-list are unit-tested.
enum InlineImagePolicy {
    /// Cap to keep a pathological multi-hundred-MB file from stalling the UI
    /// while it's decoded + sliced into the buffer.
    static let maxBytes = 24 * 1024 * 1024

    /// Raster formats NSImage decodes reliably.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    static func isRenderable(ext: String, byteCount: Int) -> Bool {
        byteCount > 0
            && byteCount <= maxBytes
            && imageExtensions.contains(ext.lowercased())
    }
}
