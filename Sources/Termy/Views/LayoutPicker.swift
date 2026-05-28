import SwiftUI

/// Visual picker for named multi-pane layouts. Cards show an accurate
/// thumbnail of the grid; tapping one spawns it. Built-ins (Quad Claude …)
/// sit first; user layouts follow with edit/delete. A star marks the layout
/// the ⌘⌥N quick-launch spawns. The editor + "save current tab" make layouts
/// user-definable without leaving the app.
struct LayoutPickerView: View {
    @EnvironmentObject var layouts: LayoutStore
    @ObservedObject var sessions: TerminalSessions
    let onDismiss: () -> Void

    @State private var editing: TermyLayout?     // non-nil → editor sheet open
    @State private var isNew = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: DS.Spacing.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: DS.Spacing.m) {
                    ForEach(layouts.all) { layout in
                        LayoutCard(
                            layout: layout,
                            isQuick: layout.id == layouts.quickLayoutID,
                            onSpawn: { spawn(layout) },
                            onSetQuick: { layouts.setQuick(layout.id) },
                            onEdit: { beginEdit(layout) },
                            onDelete: layout.isBuiltIn ? nil : { layouts.remove(layout.id) }
                        )
                    }
                }
                .padding(.bottom, DS.Spacing.s)
            }
            .frame(maxHeight: 340)
            footer
        }
        .padding(DS.Modal.padding)
        .frame(width: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.modal))
        .shadow(color: .black.opacity(DS.Modal.shadowOpacity),
                radius: DS.Modal.shadowRadius, x: 0, y: DS.Modal.shadowY)
        .sheet(item: $editing) { draft in
            LayoutEditorView(
                draft: draft,
                isNew: isNew,
                onCancel: { editing = nil },
                onSave: { saved in
                    if isNew { layouts.add(saved) } else { layouts.update(saved) }
                    editing = nil
                }
            )
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.accent)
                Text("Layouts").font(DS.Typo.title)
                Text("⌘⌥N spawns ★")
                    .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
            }
            Spacer()
            DSIconButton(icon: "xmark", action: onDismiss)
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            DSChip(icon: "plus", label: "New Layout", tint: DS.Colors.accent, isActive: false) {
                beginNew()
            }
            DSChip(icon: "square.on.square", label: "Save Current Tab", tint: nil, isActive: false) {
                saveCurrentTab()
            }
            Spacer()
            Text("\(layouts.all.count) layouts")
                .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
        }
    }

    private func spawn(_ layout: TermyLayout) {
        sessions.spawnLayout(layout)
        onDismiss()
    }

    private func beginNew() {
        isNew = true
        editing = TermyLayout(name: "New Layout", columns: 2,
                              panes: [LayoutPaneSpec(command: "claude"), LayoutPaneSpec(command: "claude")])
    }

    private func beginEdit(_ layout: TermyLayout) {
        if layout.isBuiltIn {
            // Built-ins are immutable — edit makes a customizable copy.
            isNew = true
            editing = TermyLayout(name: layout.name + " Copy", symbol: layout.symbol,
                                  columns: layout.columns, panes: layout.panes)
        } else {
            isNew = false
            editing = layout
        }
    }

    /// Capture the current tab's shape + per-pane cwd into a draft layout.
    /// Running commands can't be read back from a live shell, so commands
    /// start empty for the user to fill in the editor.
    private func saveCurrentTab() {
        guard let tab = sessions.currentTab, !tab.panes.isEmpty else { beginNew(); return }
        let cols: Int
        if let g = tab.gridColumns { cols = g }
        else if tab.orientation == .vertical { cols = 1 }
        else { cols = tab.panes.count }
        let specs = tab.panes.map { LayoutPaneSpec(cwd: $0.cwd, command: "") }
        isNew = true
        editing = TermyLayout(name: tab.customTitle ?? "My Layout",
                              columns: cols, panes: specs)
    }
}

/// One layout card: accurate thumbnail + name + shape, with hover actions.
private struct LayoutCard: View {
    let layout: TermyLayout
    let isQuick: Bool
    let onSpawn: () -> Void
    let onSetQuick: () -> Void
    let onEdit: () -> Void
    let onDelete: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ZStack(alignment: .topTrailing) {
                LayoutThumbnail(layout: layout)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.s).fill(Color.black.opacity(0.18)))
                if isQuick {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.aiAccent)
                        .padding(5)
                }
            }
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: layout.symbol)
                    .font(.system(size: 10)).foregroundStyle(DS.Colors.secondary)
                Text(layout.name).font(DS.Typo.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Text(layout.shapeLabel).font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
            }
            // Action row — visible on hover so the card stays clean at rest.
            HStack(spacing: DS.Spacing.xs) {
                Text(commandSummary)
                    .font(DS.Typo.tiny).foregroundStyle(DS.Colors.tertiary)
                    .lineLimit(1)
                Spacer()
                if hovering {
                    DSIconButton(icon: isQuick ? "star.fill" : "star", action: onSetQuick,
                                 size: 9, accessibilityLabel: "Set as quick layout")
                    DSIconButton(icon: layout.isBuiltIn ? "doc.on.doc" : "pencil", action: onEdit,
                                 size: 9, accessibilityLabel: layout.isBuiltIn ? "Duplicate" : "Edit")
                    if let onDelete {
                        DSIconButton(icon: "trash", action: onDelete, size: 9,
                                     color: DS.Colors.danger, accessibilityLabel: "Delete")
                    }
                }
            }
            .frame(height: 16)
        }
        .padding(DS.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .fill(hovering ? DS.Colors.chipBgHover : DS.Colors.chipBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .strokeBorder(isQuick ? DS.Colors.aiAccent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m))
        .onTapGesture(perform: onSpawn)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
        .help("Spawn “\(layout.name)” (\(layout.shapeLabel))")
    }

    private var commandSummary: String {
        let cmds = layout.panes.map { $0.command.isEmpty ? "shell" : $0.command }
        let unique = Array(Set(cmds))
        if unique.count == 1 { return "\(layout.paneCount)× \(unique[0])" }
        return cmds.prefix(3).joined(separator: ", ")
    }
}

/// Create / edit a layout. Columns + per-pane (command, cwd) rows. The live
/// thumbnail updates as you change the shape so it's clear what will spawn.
struct LayoutEditorView: View {
    let isNew: Bool
    let onCancel: () -> Void
    let onSave: (TermyLayout) -> Void

    @State private var name: String
    @State private var columns: Int
    @State private var panes: [LayoutPaneSpec]
    private let id: UUID
    private let symbol: String

    init(draft: TermyLayout, isNew: Bool,
         onCancel: @escaping () -> Void, onSave: @escaping (TermyLayout) -> Void) {
        self.isNew = isNew
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _columns = State(initialValue: max(1, draft.columns))
        _panes = State(initialValue: draft.panes.isEmpty ? [LayoutPaneSpec()] : draft.panes)
        self.id = draft.id
        self.symbol = draft.symbol
    }

    private var preview: TermyLayout {
        TermyLayout(id: id, name: name, symbol: symbol, columns: columns, panes: panes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack {
                Text(isNew ? "New Layout" : "Edit Layout").font(DS.Typo.title)
                Spacer()
                LayoutThumbnailPublic(layout: preview).frame(width: 64, height: 44)
            }
            DSFormRow("Name") {
                TextField("Layout name", text: $name).textFieldStyle(.roundedBorder)
            }
            DSFormRow("Columns", hint: "Panes tile row-major into this many columns. \(preview.shapeLabel) for \(panes.count) panes.") {
                Stepper(value: $columns, in: 1...4) {
                    Text("\(columns) column\(columns == 1 ? "" : "s")").font(DS.Typo.body)
                }
            }
            DSSection("Panes") {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(panes.indices, id: \.self) { i in
                        HStack(spacing: DS.Spacing.s) {
                            Text("\(i + 1)").font(DS.Typo.monoCaption).foregroundStyle(DS.Colors.tertiary)
                                .frame(width: 16)
                            TextField("command (e.g. claude) — blank = shell", text: $panes[i].command)
                                .textFieldStyle(.roundedBorder).font(DS.Typo.monoCaption)
                            TextField("cwd (blank = current)", text: $panes[i].cwd)
                                .textFieldStyle(.roundedBorder).font(DS.Typo.monoCaption)
                                .frame(width: 140)
                            DSIconButton(icon: "minus", action: { removePane(i) }, size: 9,
                                         accessibilityLabel: "Remove pane")
                                .disabled(panes.count <= 1)
                        }
                    }
                    HStack {
                        DSChip(icon: "plus", label: "Add Pane", tint: DS.Colors.accent, isActive: false) {
                            panes.append(LayoutPaneSpec(command: "claude"))
                        }
                        Spacer()
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    var l = preview
                    if l.name.trimmingCharacters(in: .whitespaces).isEmpty { l.name = "Layout" }
                    onSave(l)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(panes.isEmpty)
            }
        }
        .padding(DS.Modal.padding)
        .frame(width: 480)
    }

    private func removePane(_ i: Int) {
        guard panes.count > 1, panes.indices.contains(i) else { return }
        panes.remove(at: i)
    }
}

/// Public wrapper so the editor (different access scope) can show a thumbnail.
private struct LayoutThumbnailPublic: View {
    let layout: TermyLayout
    var body: some View { LayoutThumbnail(layout: layout) }
}

/// Accurate mini-render of a layout's grid, reusing the real cell counts so
/// the thumbnail matches what actually spawns.
private struct LayoutThumbnail: View {
    let layout: TermyLayout

    var body: some View {
        let rows = max(1, layout.rows)
        let cols = max(1, layout.columns)
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { r in
                let cells = PaneMath.gridCellsInRow(count: layout.paneCount, columns: cols, row: r)
                HStack(spacing: 2) {
                    ForEach(0..<max(1, cells), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DS.Colors.accent.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(DS.Colors.accent.opacity(0.55), lineWidth: 1))
                    }
                }
            }
        }
        .padding(6)
    }
}
