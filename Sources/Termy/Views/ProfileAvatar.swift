import SwiftUI

/// Loads a Tapback memoji over HTTP and renders it as a circular avatar.
/// SwiftUI's AsyncImage handles fetching + caching via URLSession's shared
/// URLCache, so a profile's avatar pays the network cost once per launch.
/// Falls back to a tinted initial circle while loading or if the request
/// fails (offline, DNS down, etc.) so the row never breaks.
struct ProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        Group {
            if let url = profile.avatarURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// Pleasant fallback while the memoji is loading or if the request fails:
    /// a soft-tinted circle showing the profile's initial.
    private var fallback: some View {
        ZStack {
            Circle().fill(tintFromSeed.opacity(0.35))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first ?? "•").uppercased()
    }

    /// Stable color derived from the avatar seed so the fallback looks
    /// distinct per profile even before the network image lands.
    private var tintFromSeed: Color {
        let hash = profile.avatarSeed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hues: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .yellow, .mint, .cyan]
        return hues[abs(hash) % hues.count]
    }
}
