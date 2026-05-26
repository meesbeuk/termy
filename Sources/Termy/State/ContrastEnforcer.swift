import AppKit

/// Forces foreground/background pairs above a minimum WCAG contrast ratio.
/// If the picked theme's foreground/background pair is below the user's
/// `minimumContrast` floor, the foreground is nudged toward white or black
/// (whichever direction increases contrast against the background) until
/// the floor is crossed. The chroma of the original is preserved as much as
/// possible — we lift toward white in HSB space, not full RGB.
///
/// Ratio formula from WCAG 2.1 §1.4.3:
///     (Lᵢ + 0.05) / (L_smaller + 0.05)
/// where L is relative luminance per the IEC 61966-2-1 sRGB transfer.
enum ContrastEnforcer {
    static func enforce(foreground: NSColor, background: NSColor, minRatio: Double) -> NSColor {
        guard let fgSRGB = foreground.usingColorSpace(.sRGB),
              let bgSRGB = background.usingColorSpace(.sRGB) else {
            return foreground
        }
        let bgL = relativeLuminance(bgSRGB)
        var fgL = relativeLuminance(fgSRGB)
        if contrastRatio(bgL, fgL) >= minRatio {
            return foreground
        }
        // Decide which way to push. If the background is dark, lifting the
        // foreground toward white gains contrast; if light, pushing toward
        // black does. We do this in HSB space (Hue/Sat fixed, Brightness
        // moved) so the user's theme accent stays recognizable — e.g. a
        // muted blue stays blue, just brighter.
        let pushTowardWhite = bgL < 0.5
        var (h, s, b, a) = hsba(fgSRGB)
        // Newton-ish ramp: max 30 small steps. Past that the original
        // theme was so washed-out that we'd be lying to say "we got it
        // there"; cap at whatever's closest.
        let step: CGFloat = 0.03
        for _ in 0..<30 {
            if pushTowardWhite {
                b = min(1.0, b + step)
                s = max(0.0, s - step * 0.5)  // desaturate slightly as we approach white
            } else {
                b = max(0.0, b - step)
            }
            let candidate = NSColor(hue: h, saturation: s, brightness: b, alpha: a)
            if let candSRGB = candidate.usingColorSpace(.sRGB) {
                fgL = relativeLuminance(candSRGB)
                if contrastRatio(bgL, fgL) >= minRatio {
                    return candidate
                }
            }
            if (pushTowardWhite && b >= 1.0) || (!pushTowardWhite && b <= 0.0) {
                break
            }
        }
        return NSColor(hue: h, saturation: s, brightness: b, alpha: a)
    }

    private static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func relativeLuminance(_ c: NSColor) -> Double {
        let r = sRGBToLinear(Double(c.redComponent))
        let g = sRGBToLinear(Double(c.greenComponent))
        let b = sRGBToLinear(Double(c.blueComponent))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func sRGBToLinear(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func hsba(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b, a)
    }
}
