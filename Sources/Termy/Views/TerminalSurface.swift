import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView`.
/// Each instance owns a separate shell process — its lifecycle is tied to the
/// `TerminalSession` model, not to the view tree, so tab switches don't fork
/// new shells.
struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let existing = session.terminalView {
            applyAppearance(existing)
            return existing
        }

        let view = LocalProcessTerminalView(frame: .zero)
        applyAppearance(view)
        // CRITICAL: autoresizing makes AppKit propagate every superview size
        // change down to this view, which fires SwiftTerm's setFrameSize →
        // grid relayout → clean redraw. Without this, the SwiftUI hosting
        // layer absorbs size changes and SwiftTerm never sees them, leaving
        // stale rendered text behind on every window drag.
        view.autoresizingMask = [.width, .height]
        view.registerForDraggedTypes([.fileURL])

        // Bridge process state back to the session model — title/cwd updates,
        // termination, etc. Coordinator pattern keeps the delegate alive.
        view.processDelegate = context.coordinator

        view.startProcess(
            executable: session.shellPath,
            args: session.shellArgs,
            environment: session.processEnvironment,
            execName: nil,
            currentDirectory: session.initialCwd
        )

        session.terminalView = view
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applyAppearance(nsView)
        // Autoresizing handles size sync — no manual frame poke needed.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, sessions: sessions)
    }

    /// Visual tuning to match the rest of the suite — dark glass background,
    /// SF Mono, generous line spacing, transparent fill so the window's glass
    /// shows through the terminal area.
    private func applyAppearance(_ view: LocalProcessTerminalView) {
        let size = settings.fontSize
        let font = NSFont(name: settings.fontFamily, size: size)
            ?? NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        view.font = font

        // TODO(cursor): SwiftTerm's caret style isn't in its public API surface
        // yet — `caretView` and `style` are internal. Settings.cursorStyle is
        // persisted and will plug in when SwiftTerm exposes it, or via OSC
        // sequences emitted by the shell prompt.

        // Fully transparent — the window's adaptive backdrop is the single
        // source of opacity for the entire app. No per-element backgrounds.
        view.nativeBackgroundColor = NSColor.clear
        let (fr, fg, fb) = settings.theme.foreground
        view.nativeForegroundColor = NSColor(
            red: CGFloat(fr) / 255, green: CGFloat(fg) / 255, blue: CGFloat(fb) / 255, alpha: 1.0
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        view.installColors(settings.theme.swiftTermColors)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        let sessions: TerminalSessions

        init(session: TerminalSession, sessions: TerminalSessions) {
            self.session = session
            self.sessions = sessions
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm handles PTY resize internally; nothing extra to do.
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            DispatchQueue.main.async {
                if !title.isEmpty { self.session.title = title }
            }
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            DispatchQueue.main.async {
                if let dir = directory, !dir.isEmpty {
                    self.session.cwd = dir
                    self.sessions.persist()    // restored tabs follow the live cwd
                }
            }
        }

        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
            // Auto-close just THIS pane (closePane handles tab/window cascade).
            // closeTab(session.id) was wrong — session.id is a pane id, not a tab id.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sessions.closePane(self.session.id)
            }
        }
    }
}
