import SwiftUI
import AppKit
import ObjectiveC.runtime
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView`.
/// Each instance owns a separate shell process — its lifecycle is tied to the
/// `TerminalSession` model, not to the view tree, so tab switches don't fork
/// new shells.
/// Subclass that hooks the bell so we can fire a notification when an
/// unfocused window beeps. Overriding the view-level `bell(source: Terminal)`
/// is safe — it doesn't touch the terminalDelegate (replacing that would
/// disconnect keyboard input, as v0.8.0–0.8.2 painfully proved).
final class TermyTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    // MARK: - Live-resize coalescing
    //
    // SwiftTerm's setFrameSize calls `processSizeChange` → `terminal.resize` →
    // `reflowWider` on every AppKit setFrameSize tick. During a window-corner
    // drag AppKit fires that hundreds of times per second with intermediate
    // widths, and SwiftTerm's reflowWider corrupts scrollback when called
    // repeatedly — wrapped-continuation lines get dropped without their
    // contents being merged into the surviving line, so when you scroll back
    // up after resize you see disconnected text fragments at random columns.
    //
    // Skip SwiftTerm's reflow during live resize and run it exactly once when
    // the drag ends. NSView's own setFrameSize still runs so AppKit's layout
    // pass is consistent — we hand-dispatch to it via the objc runtime to
    // bypass SwiftTerm's override.

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Re-run SwiftTerm's setFrameSize once at the final size so it does
        // a single reflow from old cols → new cols, instead of N tiny ones.
        // SwiftTerm's processSizeChange early-returns when the size matches
        // the current frame, so nudge by half a point first to force the
        // reflow to run, then settle on the real size.
        let final = frame.size
        super.setFrameSize(NSSize(width: final.width + 0.5, height: final.height))
        super.setFrameSize(final)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard inLiveResize else {
            super.setFrameSize(newSize)
            return
        }
        // In a live resize: update NSView's frame directly, skipping
        // SwiftTerm's per-tick terminal.resize. The cell grid stays at its
        // previous (cols × rows) for the duration of the drag — the rendered
        // text shifts slightly in the window while the user is dragging, but
        // the scrollback buffer is not mutated.
        callNSViewSetFrameSize(newSize)
        needsDisplay = true
    }

    private func callNSViewSetFrameSize(_ newSize: NSSize) {
        typealias Fn = @convention(c) (NSView, Selector, NSSize) -> Void
        let sel = #selector(NSView.setFrameSize(_:))
        guard let impl = class_getMethodImplementation(NSView.self, sel) else {
            // Shouldn't happen — NSView always responds to setFrameSize.
            // Fall back to super so we at least don't crash on resize.
            super.setFrameSize(newSize)
            return
        }
        unsafeBitCast(impl, to: Fn.self)(self, sel, newSize)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var settings: TerminalSettings

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let existing = session.terminalView {
            applyAppearance(existing)
            return existing
        }

        let view = TermyTerminalView(frame: .zero)
        view.onBell = { [weak session] in
            guard let session else { return }
            TermyNotifications.shared.bell(
                window: session.terminalView?.window,
                cwd: session.cwd
            )
        }
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
        // NOTE: do NOT overwrite view.terminalDelegate. LocalProcessTerminalView
        // is its own TerminalViewDelegate (see SwiftTerm's MacLocalTerminalView
        // init) and routes `send(source:data:)` to the PTY's stdin. Replacing
        // it with our own delegate would silently disconnect keyboard input.
        // SwiftTerm's macOS default already opens URLs via NSWorkspace.

        view.startProcess(
            executable: session.shellPath,
            args: session.shellArgs,
            environment: session.processEnvironment,
            execName: nil,
            currentDirectory: session.initialCwd
        )

        session.terminalView = view

        // If the session was opened to run a file the OS handed us, type the
        // command into the shell once it's had a moment to print its prompt.
        // ~0.4s is enough for zsh --login to source rc files; sending too
        // early causes the command to appear before the prompt.
        if let cmd = session.pendingInitialCommand {
            session.pendingInitialCommand = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
                view?.send(txt: cmd + "\r")
            }
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Skip the full re-apply when nothing the view cares about has
        // changed. Avoids reallocating 16 NSColors per parent re-render
        // (hover-state changes in the title strip trigger updateNSView).
        let stamp = "\(settings.themeID)|\(Int(settings.fontSize))|\(settings.fontFamily)"
        if context.coordinator.lastAppearanceStamp != stamp {
            applyAppearance(nsView)
            context.coordinator.lastAppearanceStamp = stamp
        }
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

        // Cursor style: SwiftTerm's public surface doesn't expose this in a
        // way we can reliably set, and the DECSCUSR escape sequence path
        // corrupted the buffer when fed pre-startProcess. Settings are
        // persisted but the toggle is currently visual-only.

        // Fully transparent — the window's adaptive backdrop is the single
        // source of opacity for the entire app. No per-element backgrounds.
        view.nativeBackgroundColor = NSColor.clear
        let (fr, fg, fb) = settings.theme.foreground
        let foreground = NSColor(
            red: CGFloat(fr) / 255, green: CGFloat(fg) / 255, blue: CGFloat(fb) / 255, alpha: 1.0
        )
        view.nativeForegroundColor = foreground
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        // Caret defaults to NSColor.selectedControlColor (system accent), which
        // disappears on dark wallpapers/themes since the window's bg is clear
        // glass. Pin it to the theme's foreground so the cursor is always
        // visible, and use ansi[0] (the theme's intended bg) as the inverse
        // text color so a character under the caret stays legible.
        view.caretColor = foreground
        let (br, bg, bb) = settings.theme.ansi[0]
        view.caretTextColor = NSColor(
            red: CGFloat(br) / 255, green: CGFloat(bg) / 255, blue: CGFloat(bb) / 255, alpha: 1.0
        )

        view.installColors(settings.theme.swiftTermColors)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        let sessions: TerminalSessions
        /// Last appearance signature (theme|font|cursor) we applied — used to
        /// skip redundant `applyAppearance` calls when nothing visual changed.
        var lastAppearanceStamp: String = ""
        /// Debounce timer for persisting cwd changes. Heavy `cd` workflows
        /// otherwise produce hundreds of UserDefaults writes per second.
        private var persistTimer: Timer?

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
                    // Debounce persist — `cd`-heavy workflows hit this on every
                    // hop, and UserDefaults writes are not free.
                    self.persistTimer?.invalidate()
                    self.persistTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async { self?.sessions.persist() }
                    }
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
