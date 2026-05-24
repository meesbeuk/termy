import SwiftUI
import AppKit

/// Renders a LobeHub-style brand SVG bundled in Resources/LaunchIcons/.
/// Loads as a template image so SwiftUI `foregroundStyle` tints it cleanly
/// (all icons ship monochrome with `fill="currentColor"`).
///
/// Falls back to an SF Symbol when the brand asset isn't present — keeps the
/// row stable while we're still building out the icon set.
struct BrandIcon: View {
    let assetName: String?
    let fallbackSymbol: String
    let size: CGFloat

    var body: some View {
        if let assetName, let image = Self.load(assetName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.9, weight: .medium))
                .frame(width: size, height: size)
        }
    }

    /// Cache so we don't re-decode the SVG on every view diff. NSImage decoding
    /// itself isn't free, and the launcher row redraws frequently on hover.
    private static var cache: [String: NSImage] = [:]

    static func load(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(
            forResource: name, withExtension: "svg", subdirectory: "LaunchIcons"
        ) else { return nil }
        guard let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true   // mask-mode → SwiftUI foregroundStyle tints it
        cache[name] = img
        return img
    }
}
