import SwiftUI

/// Deterministic local avatar derived entirely from the profile's seed.
/// No network — was a Tapback HTTP fetch through v0.9.6, but that leaked
/// avatar usage to a third party and broke avatars on offline launches.
/// Renders a soft gradient disc + the name's initial; same seed always
/// produces the same look so profiles stay visually stable.
struct ProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        ZStack {
            AngularGradient(
                gradient: Gradient(colors: gradientStops),
                center: .center,
                startAngle: .degrees(angleOffset),
                endAngle: .degrees(angleOffset + 360)
            )
            // Inner soft white wash so light initials stay readable on
            // light-hue gradients.
            Circle()
                .fill(Color.black.opacity(0.20))
                .blur(radius: size * 0.25)
            Text(initial)
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first ?? "•").uppercased()
    }

    /// Two complementary hues drawn from a 12-hue wheel so the gradient
    /// stays vivid but not chaotic. Picks by hashing the seed.
    private var gradientStops: [Color] {
        let palette: [Color] = [
            Color(red: 0.95, green: 0.42, blue: 0.45),  // coral
            Color(red: 0.96, green: 0.62, blue: 0.30),  // tangerine
            Color(red: 0.98, green: 0.80, blue: 0.36),  // amber
            Color(red: 0.50, green: 0.82, blue: 0.46),  // mint
            Color(red: 0.35, green: 0.74, blue: 0.66),  // teal
            Color(red: 0.36, green: 0.66, blue: 0.92),  // sky
            Color(red: 0.42, green: 0.45, blue: 0.92),  // indigo
            Color(red: 0.65, green: 0.43, blue: 0.92),  // violet
            Color(red: 0.92, green: 0.46, blue: 0.85),  // orchid
            Color(red: 0.78, green: 0.48, blue: 0.32),  // rust
            Color(red: 0.55, green: 0.66, blue: 0.40),  // moss
            Color(red: 0.40, green: 0.50, blue: 0.62),  // slate
        ]
        let base = seedHash % palette.count
        let pair = (seedHash / palette.count + 5) % palette.count
        return [palette[base], palette[pair], palette[base]]
    }

    private var angleOffset: Double {
        Double((seedHash * 17) % 360)
    }

    /// Stable FNV-1a-ish hash of the avatar seed. Cheap, deterministic, doesn't
    /// require Foundation's hasher (which is randomized per-process).
    private var seedHash: Int {
        var h: UInt64 = 1469598103934665603
        for byte in profile.avatarSeed.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return Int(truncatingIfNeeded: h & 0x7FFFFFFFFFFFFFFF)
    }
}
