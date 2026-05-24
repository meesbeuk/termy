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
    /// Re-applies theme + caret colors. Set by TerminalSurface so we can
    /// re-run it from `viewDidMoveToWindow` — caret colors set before the
    /// view is in a window don't render the cursor on first paint, so we
    /// have to nudge them once AppKit has us in the hierarchy. (Theme
    /// switches accidentally fix this because `updateNSView` re-applies
    /// appearance at a point when the view is already attached.)
    var onMovedToWindow: (() -> Void)?

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMovedToWindow?()
    }

    // MARK: - Live-resize coalescing
    //
    // SwiftTerm's setFrameSize calls `processSizeChange` → `terminal.resize` →
    // `reflowWider` on every AppKit setFrameSize tick. During a window-corner
    // drag AppKit fires that hundreds of times per second with intermediate
    // widths, and SwiftTerm's reflowWider has a buggy "remove wrapped
    // continuation lines" path that drops content without merging into the
    // surviving line. The net effect: scrollback gains duplicated/ghosted rows
    // and scrolling back up looks corrupt.
    //
    // Two defenses, stacked:
    //   1. Coalesce — during a live drag, skip SwiftTerm's per-tick
    //      processSizeChange so the cell grid mutates exactly once. We
    //      hand-dispatch to NSView's setFrameSize via the objc runtime to
    //      bypass SwiftTerm's override.
    //   2. Skip the reflow entirely — when the drag ends and we run the one
    //      final resize, temporarily flip the terminal's scrollback off
    //      (`isReflowEnabled = hasScrollback`, so nil disables it). The
    //      resize still rebuilds the visible grid; the buggy reflow path is
    //      simply never taken. Scrollback past the visible viewport is lost,
    //      but the alternative (corrupted, unreadable scrollback) is worse.

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Settle the grid at the final size with reflow disabled, so the
        // single resize that crosses cols/rows doesn't run reflowWider.
        // Nudge by half a point first to force processSizeChange (which
        // early-returns when the size matches the current frame).
        let final = frame.size
        withReflowDisabled {
            super.setFrameSize(NSSize(width: final.width + 0.5, height: final.height))
            super.setFrameSize(final)
        }
        // Full refresh from the buffer so any stale draw region clears.
        getTerminal().refresh(startRow: 0, endRow: getTerminal().rows - 1)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard inLiveResize else {
            // Even non-live resizes (programmatic, split-pane drag end,
            // font-size changes that mutate cell dimensions) can trip the
            // reflow bug. Always route through the reflow-off path.
            withReflowDisabled { super.setFrameSize(newSize) }
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

    /// Runs `body` with the terminal's scrollback temporarily set to nil so
    /// `Buffer.resize` skips its reflow path. Restores the prior scrollback
    /// size afterward. Visible viewport content is preserved across the
    /// toggle (changeHistorySize trims from the START of the line buffer and
    /// adjusts yBase/yDisp so the visible window stays anchored).
    private func withReflowDisabled(_ body: () -> Void) {
        let terminal = getTerminal()
        let priorScrollback = terminal.options.scrollback
        terminal.changeScrollback(nil)
        body()
        terminal.changeScrollback(priorScrollback > 0 ? priorScrollback : nil)
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
        // Re-apply once we land in a window — fixes the missing-cursor-at-
        // launch case. The struct's `applyAppearance` is value-safe to
        // capture; `self` here is the NSViewRepresentable.
        view.onMovedToWindow = { [weak view] in
            guard let view else { return }
            self.applyAppearance(view)
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
