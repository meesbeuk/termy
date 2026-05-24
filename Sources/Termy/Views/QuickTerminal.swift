import SwiftUI
import AppKit

/// Quake-style drop-down terminal. A single, persistent NSPanel that slides
/// in from the top of the active display when ⌃` is pressed, and slides
/// back out on the next ⌃` press or when it loses key focus (configurable).
///
/// Rationale for the architecture choice:
///   - SwiftUI's `WindowGroup` produces full standard windows that animate
///     however AppKit feels like animating them — not what users expect from
///     a Quake-style overlay.
///   - We need a window that stays at .floating level, doesn't change the
///     app's activation, and can slide using NSAnimationContext.
///   - An NSPanel hosted on a singleton controller hits all three.
///
/// The panel keeps its terminal session alive between toggles — repeated
/// ⌃` feels instant because no shell forks happen on show.
@MainActor
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    private var panel: QuickTerminalPanel?
    private var sessions: TerminalSessions?
    private var hideOnFocusLossObserver: Any?
    private var settingsRef: TerminalSettings?
    private var profilesRef: ProfileStore?

    /// Toggle visibility. First call lazily builds the panel; subsequent calls
    /// just show/hide the same instance.
    func toggle(settings: TerminalSettings, profiles: ProfileStore) {
        self.settingsRef = settings
        self.profilesRef = profiles
        if panel == nil { buildPanel(settings: settings, profiles: profiles) }
        guard let panel else { return }
        if panel.isVisible {
            slideOut()
        } else {
            slideIn()
        }
    }

    private func buildPanel(settings: TerminalSettings, profiles: ProfileStore) {
        let s = TerminalSessions()
        s.profileStore = profiles
        s.openTab(persistChange: false)
        self.sessions = s

        let frame = collapsedFrame()
        let p = QuickTerminalPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Quick Terminal"
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Drop the shadow on the bottom edge — looks intentional for a
        // panel that lives flush with the top of the screen.
        p.isMovable = false

        let root = QuickTerminalRoot(onEscape: { [weak self] in self?.slideOut() })
            .environmentObject(s)
            .environmentObject(settings)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSVisualEffectView(frame: frame)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        p.contentView = container
        self.panel = p

        // Auto-hide on focus loss. Controlled by Settings → Quake →
        // "Hide on focus loss" (default on, classic Quake behavior). When
        // off, the panel stays put even when the user clicks elsewhere.
        let nc = NotificationCenter.default
        hideOnFocusLossObserver = nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            // Defer to next runloop — without this, clicking inside the
            // panel transiently resigns key (during the click hit-test) and
            // hides itself mid-interaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible,
                      !panel.isKeyWindow,
                      self.settingsRef?.quakeHideOnFocusLoss ?? true
                else { return }
                self.slideOut()
            }
        }
    }

    /// Display the panel on whichever screen currently owns the focus —
    /// i.e. the screen containing the mouse cursor when the user pressed
    /// ⌃`. NSScreen.main reflects the menubar-owning screen, which on
    /// multi-monitor setups is often NOT where the user is working. Falls
    /// back to .main when no mouseScreen is available (e.g. headless tests).
    private func screen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        let hit = NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
        return hit ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private func expandedFrame() -> NSRect {
        let s = screen()
        let v = s.visibleFrame
        let fraction = settingsRef?.quakeHeightFraction ?? 0.45
        let height = round(v.height * fraction)
        return NSRect(x: v.minX, y: s.frame.maxY - height, width: v.width, height: height)
    }

    private func collapsedFrame() -> NSRect {
        let f = expandedFrame()
        return NSRect(x: f.minX, y: f.maxY, width: f.width, height: f.height)
    }

    private func slideIn() {
        guard let panel else { return }
        // Reposition for current display in case the user changed screens.
        let target = expandedFrame()
        let start = collapsedFrame()
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        })
    }

    private func slideOut() {
        guard let panel else { return }
        let end = collapsedFrame()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }
}

/// Borderless panel that can become key so the terminal accepts keystrokes.
/// NSPanel defaults canBecomeKey to false for non-titled panels — overriding
/// is the supported way (per Apple's NSPanel docs).
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickTerminalRoot: View {
    @EnvironmentObject var sessions: TerminalSessions
    @EnvironmentObject var settings: TerminalSettings
    let onEscape: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let tab = sessions.currentTab {
                PaneLayout(tab: tab, sessions: sessions, settings: settings)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
            // Slim handle so the panel reads as a drop-down, not a notification.
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 3)
                    .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            // Top-right close × so users have a visible exit affordance
            // beyond ⌃` and ⎋. Without it, the only way to dismiss is
            // muscle-memory + the hint in the cheatsheet.
            HStack {
                Spacer()
                Button(action: onEscape) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(.regularMaterial).opacity(0.7)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss Quick Terminal (⌃` or ⎋)")
                .accessibilityLabel("Dismiss Quick Terminal")
                .padding(.top, 6)
                .padding(.trailing, 12)
            }
        }
        // ⎋ explicitly dismisses — matches every quake terminal in the wild.
        .background(
            Button("") { onEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        )
    }
}
