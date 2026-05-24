import AppKit
import CoreImage

/// Reads the desktop wallpaper for a given screen and computes its average
/// brightness (luminance) on a 0.0–1.0 scale.
/// Used by the auto-opacity feature to pick a sane terminal background opacity:
/// light wallpapers need more opaque terminals; dark wallpapers can be more glassy.
enum WallpaperBrightness {
    /// Returns nil if we can't read the wallpaper (no screen, no file, etc.)
    static func detect(for screen: NSScreen?) -> Double? {
        let workspace = NSWorkspace.shared
        let target = screen ?? NSScreen.main
        guard let target,
              let url = workspace.desktopImageURL(for: target)
        else { return nil }
        guard let img = CIImage(contentsOf: url) else { return nil }

        // Downsample by computing the average color filter — efficient + accurate.
        let extent = img.extent
        let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: img,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])
        guard let output = avgFilter?.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        // Rec. 709 luminance.
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Map a wallpaper luminance to the window's single-layer dark tint.
    /// This is the ONLY opacity in the app now — covers the entire window,
    /// including the terminal area. Needs enough opacity at the high end for
    /// readable text over white backdrops; stays glass-like at the low end.
    static func opacity(forBrightness lum: Double) -> Double {
        let minOpacity = 0.10   // dark wallpaper — let the glass show through
        let maxOpacity = 0.55   // light wallpaper — opaque enough to read
        return minOpacity + lum * (maxOpacity - minOpacity)
    }
}
