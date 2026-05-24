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

        // Auto-hide on focus loss. We can disable later via a settings
        // toggle; for now this is the standard Quake behavior.
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
                      !panel.isKeyWindow else { return }
                self.slideOut()
            }
        }
    }

    private func screen() -> NSScreen {
        NSScreen.main ?? NSScreen.screens.first!
    }

    private func expandedFrame() -> NSRect {
        let s = screen()
        let v = s.visibleFrame
        let height = round(v.height * 0.45)
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
                    .padding(.top, 8)
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
        }
        // ⎋ explicitly dismisses — matches every quake terminal in the wild.
        .background(
            Button("") { onEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
        )
    }
}
