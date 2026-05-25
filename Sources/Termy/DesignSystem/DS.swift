import SwiftUI
import AppKit

/// Termy design system — single source of truth for fonts, spacing, colors,
/// corners, shadows. Anything visual should pull from here. Change a token
/// once, every modal/widget/icon updates.
enum DS {
    // MARK: - Spacing scale (4-pt grid)
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let s:   CGFloat = 6
        static let m:   CGFloat = 10
        static let l:   CGFloat = 14
        static let xl:  CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - Corner radii
    enum Radius {
        static let xs:    CGFloat = 4
        static let s:     CGFloat = 6
        static let m:     CGFloat = 8
        static let l:     CGFloat = 12
        static let xl:    CGFloat = 16
        static let modal: CGFloat = 14
    }

    // MARK: - Typography
    enum Typo {
        static let title    = Font.system(size: 14, weight: .semibold)
        static let header   = Font.system(size: 12, weight: .semibold)
        static let body     = Font.system(size: 12)
        static let caption  = Font.system(size: 11)
        static let micro    = Font.system(size: 10)
        static let tiny     = Font.system(size: 9)
        static let monoMicro = Font.system(size: 10, design: .monospaced)
        static let monoCaption = Font.system(size: 11, design: .monospaced)
    }

    // MARK: - Colors (semantic)
    enum Colors {
        static let accent  = Color.accentColor
        static let primary = Color.primary
        static let secondary = Color.secondary
        static let tertiary  = Color(nsColor: .tertiaryLabelColor)
        static let danger    = Color.red
        static let success   = Color.green
        static let aiAccent  = Color.orange   // Vibecoder / AI affordances
        static let chipBg    = Color.primary.opacity(0.08)
        static let chipBgHover = Color.primary.opacity(0.13)
        static let chipBgActive = Color.primary.opacity(0.18)
        static let divider   = Color.white.opacity(0.10)
    }

    // MARK: - Modal/Sheet sizing
    enum Modal {
        static let width: CGFloat = 380
        static let padding: CGFloat = 20
        static let shadowOpacity: Double = 0.30
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = 6
    }
}

// MARK: - Modal shell — used by every Termy modal/sheet/overlay

/// Canonical modal chrome. Every panel/sheet in Termy wraps its content with
/// this so the look is uniform: regular material, rounded, shadowed, with a
/// title row + close button, and optional footer hint.
struct DSModal<Content: View>: View {
    let title: String
    let titleIcon: String?
    let titleIconColor: Color
    let footerHint: String?
    let onClose: () -> Void
    let content: Content

    init(
        title: String,
        titleIcon: String? = nil,
        titleIconColor: Color = DS.Colors.accent,
        footerHint: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleIcon = titleIcon
        self.titleIconColor = titleIconColor
        self.footerHint = footerHint
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            header
            content
            if let footerHint {
                Text(footerHint)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
            }
        }
        .padding(DS.Modal.padding)
        .frame(maxWidth: DS.Modal.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(
            color: .black.opacity(DS.Modal.shadowOpacity),
            radius: DS.Modal.shadowRadius,
            x: 0, y: DS.Modal.shadowY
        )
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                if let icon = titleIcon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(titleIconColor)
                }
                Text(title)
                    .font(DS.Typo.title)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onClose)
        }
    }
}

// MARK: - Icon button — small ⊕/×/⚙ style action button

struct DSIconButton: View {
    let icon: String
    let action: () -> Void
    var size: CGFloat = 11
    var color: Color = DS.Colors.secondary
    /// Accessibility label for VoiceOver. Falls back to the SF Symbol's
    /// own description when nil; setting an explicit label is preferred
    /// because SwiftUI's default reads e.g. "xmark, button" which is
    /// less informative than "Close, button".
    var accessibilityLabel: String? = nil

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .fill(hovering ? DS.Colors.chipBgHover : Color.clear)
                )
                .contentShape(Rectangle())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? defaultLabel)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }

    private var defaultLabel: String {
        // Friendly defaults for the icons we use everywhere.
        switch icon {
        case "xmark": return "Close"
        case "chevron.up": return "Previous"
        case "chevron.down": return "Next"
        case "pencil": return "Edit"
        case "trash": return "Delete"
        case "plus": return "Add"
        default: return icon
        }
    }
}

// MARK: - Form row — label + control

struct DSFormRow<Control: View>: View {
    let label: String
    let hint: String?
    let control: Control

    init(_ label: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label)
                .font(DS.Typo.caption.weight(.medium))
                .foregroundStyle(DS.Colors.secondary)
            control
            if let hint {
                Text(hint)
                    .font(DS.Typo.tiny)
                    .foregroundStyle(DS.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Section header inside a modal

struct DSSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .textCase(.uppercase)
                .opacity(0.7)
            content
        }
    }
}

// MARK: - Pill / chip used in tab bar, vibecoder row, etc.

struct DSChip: View {
    let icon: String?
    let label: String
    let tint: Color?
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint ?? DS.Colors.secondary)
                }
                Text(label)
                    .font(DS.Typo.micro.weight(.medium))
                    .foregroundStyle(DS.Colors.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(bgColor))
            .overlay(Capsule().strokeBorder(DS.Colors.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { newValue in
            withAnimation(.easeOut(duration: 0.10)) { hovering = newValue }
        }
    }

    private var bgColor: Color {
        if isActive { return DS.Colors.chipBgActive }
        if hovering { return DS.Colors.chipBgHover }
        return DS.Colors.chipBg
    }
}
