import SwiftUI
import TouchCodeCore

/// Settings → Shortcuts pane. Lists every entry in `ShortcutSchema.app` grouped by
/// category, lets the user record a new chord, disable a chord, reset one row, or restore
/// every row to its default. Conflict feedback during recording surfaces inline; cascading
/// resets present a confirmation dialog before applying.
///
/// Layout follows the macOS System-Settings convention: a hierarchical `Table` with
/// `DisclosureTableRow` group headers, alternating row backgrounds, search routed through
/// `.searchable(.toolbar)`, and a primary toolbar action for "Restore Defaults". The
/// behavioural surface (recording, conflict resolution, reset planning) is unchanged
/// from the previous custom-painted pane.
struct ShortcutsSettingsView: View {
  @Bindable var store: ShortcutsStore
  @State private var query: String = ""
  @State private var pendingConflict: PendingConflict?
  @State private var pendingReset: ShortcutResetPlan?
  @State private var showRestoreAllConfirmation: Bool = false
  /// Categories that are expanded in the outline. Defaults to "all expanded" so the pane
  /// opens fully populated; subsequent collapses persist for the lifetime of the window.
  @State private var expandedCategories: Set<String> = Set(
    ShortcutSchema.Category.allCases.map(\.rawValue)
  )

  var body: some View {
    Table(of: ShortcutTableItem.self) {
      TableColumn("Name") { item in
        NameCell(item: item)
      }
      TableColumn("Shortcut") { item in
        HotkeyCell(
          item: item,
          store: store,
          validate: validate,
          onCommit: commit,
          onReset: requestReset
        )
      }
      .width(min: 160, ideal: 200, max: 260)
      TableColumn("Enabled") { item in
        EnabledCell(item: item, store: store)
      }
      .width(min: 60, max: 90)
    } rows: {
      ForEach(tableItems) { group in
        DisclosureTableRow(
          group,
          isExpanded: Binding(
            get: { expandedCategories.contains(group.id) },
            set: { expanded in
              if expanded {
                expandedCategories.insert(group.id)
              } else {
                expandedCategories.remove(group.id)
              }
            }
          )
        ) {
          if let children = group.children {
            ForEach(children) { TableRow($0) }
          }
        }
      }
    }
    .alternatingRowBackgrounds()
    .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showRestoreAllConfirmation = true
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .accessibilityLabel("Restore Defaults")
        }
        .help("Restore all shortcuts to their default values.")
        .disabled(store.overrides.overrides.isEmpty)
      }
    }
    .confirmationDialog(
      restoreAllTitle,
      isPresented: $showRestoreAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Restore Defaults", role: .destructive) {
        store.resetAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This clears every custom keyboard shortcut and disabled flag.")
    }
    .confirmationDialog(
      resetDialogTitle,
      isPresented: resetDialogBinding,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) {
        if let plan = pendingReset {
          store.applyResetPlan(plan)
        }
        pendingReset = nil
      }
      Button("Cancel", role: .cancel) {
        pendingReset = nil
      }
    } message: {
      Text(resetDialogMessage)
    }
    .confirmationDialog(
      conflictDialogTitle,
      isPresented: conflictDialogBinding,
      titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive) {
        if let pending = pendingConflict {
          store.resolveConflict(
            disabling: pending.conflictingID,
            assigning: pending.target,
            to: pending.binding
          )
        }
        pendingConflict = nil
      }
      Button("Cancel", role: .cancel) {
        pendingConflict = nil
      }
    } message: {
      Text(conflictDialogMessage)
    }
  }

  // MARK: - Table model

  /// Group → entries projection for the outline table. Filtered by `query`.
  private var tableItems: [ShortcutTableItem] {
    visibleCategories.map { category in
      ShortcutTableItem(
        id: category.rawValue,
        kind: .group(category),
        children: filteredEntries(for: category).map { entry in
          ShortcutTableItem(
            id: entry.id.rawValue,
            kind: .entry(entry),
            children: nil
          )
        }
      )
    }
  }

  // MARK: - Mutations

  /// Hard rejections that surface as in-popover red text + shake. Internal conflicts
  /// (`commit` below) are *not* checked here — those land in a Replace-existing dialog
  /// instead so the user can promote the new chord by demoting the holder.
  private func validate(_ binding: ShortcutBinding, for _: CommandID) -> HotkeyRecorderPopover.ValidationResult {
    let symbolicHotkeyDefaults = UserDefaults(suiteName: "com.apple.symbolichotkeys") ?? .standard
    if SystemReservedDetector.isReserved(
      keyCode: binding.keyCode,
      modifiers: binding.modifiers,
      in: symbolicHotkeyDefaults
    ) {
      return .rejected(message: "Reserved by macOS system.")
    }
    if AppKitReservedDetector.isReserved(keyCode: binding.keyCode, modifiers: binding.modifiers) {
      return .rejected(message: "Reserved by macOS standard menus.")
    }
    return .ok
  }

  /// Run after `validate` returns `.ok`. Routes through the internal-conflict planner so
  /// chords already used by another command surface the Replace dialog instead of silently
  /// overwriting; otherwise commits straight to the override store.
  private func commit(_ binding: ShortcutBinding, for id: CommandID) {
    if let conflictingID = InternalConflictDetector.conflicts(
      in: store.resolved, candidate: binding, excluding: id
    ) {
      pendingConflict = PendingConflict(
        target: id, binding: binding, conflictingID: conflictingID
      )
      return
    }
    store.update(id, to: binding)
  }

  private func requestReset(for id: CommandID) {
    let plan = ShortcutResetPlanner.plan(
      resetting: id, schema: .app, overrides: store.overrides
    )
    pendingReset = plan
  }

  // MARK: - Filtering

  private var visibleCategories: [ShortcutSchema.Category] {
    ShortcutSchema.Category.allCases.filter { !filteredEntries(for: $0).isEmpty }
  }

  private func filteredEntries(for category: ShortcutSchema.Category) -> [ShortcutSchema.Entry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    return ShortcutSchema.app.entries
      .filter { $0.category == category }
      .filter { entry in
        guard !trimmed.isEmpty else { return true }
        if entry.title.lowercased().contains(trimmed) { return true }
        if let binding = store.resolved[entry.id]?.binding,
          ShortcutDisplay.chord(for: binding).lowercased().contains(trimmed)
        {
          return true
        }
        return false
      }
  }

  // MARK: - Dialogs

  fileprivate struct PendingConflict: Equatable {
    let target: CommandID
    let binding: ShortcutBinding
    let conflictingID: CommandID
  }

  private var conflictDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingConflict != nil },
      set: { presented in
        if !presented { pendingConflict = nil }
      }
    )
  }

  private var conflictDialogTitle: String { "Replace Existing Shortcut?" }
  private var conflictDialogMessage: String {
    guard let pending = pendingConflict,
      let conflictingTitle = ShortcutSchema.app.entry(for: pending.conflictingID)?.title
    else { return "" }
    return "This chord is currently bound to ‘\(conflictingTitle)’. Replacing will disable that shortcut."
  }

  private var resetDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingReset != nil },
      set: { presented in
        if !presented { pendingReset = nil }
      }
    )
  }

  private var resetDialogTitle: String { "Restore Default?" }
  private var resetDialogMessage: String {
    guard let plan = pendingReset else { return "" }
    if plan.cascadingResets.isEmpty {
      let title = ShortcutSchema.app.entry(for: plan.target)?.title ?? plan.target.rawValue
      return "Restore the default chord for ‘\(title)’."
    }
    let titles = plan.cascadingResets
      .compactMap { ShortcutSchema.app.entry(for: $0)?.title }
      .map { "‘\($0)’" }
      .joined(separator: ", ")
    let target = ShortcutSchema.app.entry(for: plan.target)?.title ?? plan.target.rawValue
    return "Resetting ‘\(target)’ will also reset \(titles) so the chords no longer collide."
  }

  private var restoreAllTitle: String { "Restore All Defaults?" }
}

// MARK: - Table model

/// Row model for the outline `Table`. Categories are group rows with `children`; individual
/// shortcuts are leaf rows.
struct ShortcutTableItem: Identifiable {
  enum Kind {
    case group(ShortcutSchema.Category)
    case entry(ShortcutSchema.Entry)
  }
  let id: String
  let kind: Kind
  let children: [ShortcutTableItem]?
}

// MARK: - Cells

private struct NameCell: View {
  let item: ShortcutTableItem

  var body: some View {
    switch item.kind {
    case .group(let category):
      Text(category.title)
        .font(.body.weight(.semibold))
    case .entry(let entry):
      Text(entry.title)
        .font(.body)
    }
  }
}

private struct HotkeyCell: View {
  let item: ShortcutTableItem
  @Bindable var store: ShortcutsStore
  let validate: (ShortcutBinding, CommandID) -> HotkeyRecorderPopover.ValidationResult
  let onCommit: (ShortcutBinding, CommandID) -> Void
  let onReset: (CommandID) -> Void

  /// One popover per cell. Tapping the chord button toggles this on; the popover dismisses
  /// itself on capture / cancel via the recorder's own task scheduling. Keeping the state
  /// per-cell (instead of pane-wide) means closing one row's popover doesn't disturb any
  /// other row, and the popover's `.popover` anchor naturally re-targets when rows
  /// re-order under search filtering.
  @State private var isRecording = false

  var body: some View {
    switch item.kind {
    case .group:
      EmptyView()
    case .entry(let entry):
      let resolved = store.resolved[entry.id]
      HStack(spacing: 8) {
        chordButton(entry: entry, resolved: resolved)
          .frame(maxWidth: .infinity, alignment: .leading)
        if entry.scope == .configurable, resolved?.source == .userOverride {
          Button {
            onReset(entry.id)
          } label: {
            Image(systemName: "arrow.uturn.backward.circle")
              .accessibilityLabel("Restore default")
          }
          .buttonStyle(.borderless)
          .help("Restore default")
        }
      }
      .contextMenu {
        if entry.scope == .configurable {
          Button("Change Shortcut…") { isRecording = true }
          if let resolved {
            Divider()
            if resolved.isEnabled {
              Button("Disable Shortcut") { store.disable(entry.id) }
            } else {
              Button("Enable Shortcut") {
                EnabledCell.restoreEnabled(for: entry.id, resolved: resolved, store: store)
              }
            }
          }
        }
      }
    }
  }

  /// Configurable rows are buttons that toggle a `HotkeyRecorderPopover`; non-configurable
  /// rows render the chord as a static bordered cell since the user cannot rebind them.
  /// The production schema currently has no non-configurable entries; the branch stays as
  /// defensive support for future `.systemFixed` / `.localOnly` rows.
  ///
  /// Configurable rows use `.buttonStyle(.plain)` — the chord renders as plain monospaced
  /// text with no chrome so it reads cleanly against the alternating row background. The
  /// `contentShape` keeps the row clickable across its full width despite the lack of a
  /// visible button border.
  @ViewBuilder
  private func chordButton(entry: ShortcutSchema.Entry, resolved: ResolvedShortcut?) -> some View {
    if entry.scope == .configurable {
      Button {
        isRecording = true
      } label: {
        chordLabel(resolved: resolved)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $isRecording, arrowEdge: .bottom) {
        HotkeyRecorderPopover(
          title: entry.title,
          validate: { validate($0, entry.id) },
          onCommit: { onCommit($0, entry.id) },
          onCancel: { isRecording = false }
        )
      }
    } else {
      HStack {
        chordLabel(resolved: resolved)
        Spacer()
      }
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func chordLabel(resolved: ResolvedShortcut?) -> some View {
    if let resolved, let binding = resolved.binding {
      Text(ShortcutDisplay.chord(for: binding))
        .font(.system(size: 14, design: .monospaced))
        .tracking(1.5)
        .foregroundStyle(chordColor(for: resolved))
        .strikethrough(!resolved.isEnabled)
    } else {
      Text("Unassigned")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
  }

  /// Accent color marks a user override; default chords stay neutral so the override stands
  /// out at a glance. Disabled rows fall through to `.secondary` regardless of source.
  private func chordColor(for resolved: ResolvedShortcut) -> Color {
    guard resolved.isEnabled else { return .secondary }
    switch resolved.source {
    case .schemaDefault: return .primary
    case .userOverride: return .accentColor
    }
  }
}

private struct EnabledCell: View {
  let item: ShortcutTableItem
  @Bindable var store: ShortcutsStore

  var body: some View {
    switch item.kind {
    case .group:
      EmptyView()
    case .entry(let entry):
      if entry.scope == .configurable {
        let resolved = store.resolved[entry.id]
        Toggle(
          "",
          isOn: Binding(
            get: { resolved?.isEnabled ?? true },
            set: { newValue in
              if newValue, let resolved {
                Self.restoreEnabled(for: entry.id, resolved: resolved, store: store)
              } else {
                store.disable(entry.id)
              }
            }
          )
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        EmptyView()
      }
    }
  }

  /// Re-enable `id`. If the row currently has a user override, flip its `isEnabled` flag back
  /// to true; otherwise the row inherits the schema default and `clear` is a no-op safeguard.
  /// Exposed as a static so the chord cell's context menu can share the same recovery path.
  static func restoreEnabled(
    for id: CommandID,
    resolved: ResolvedShortcut,
    store: ShortcutsStore
  ) {
    guard let binding = resolved.binding else { return }
    let enabled = ShortcutBinding(
      keyCode: binding.keyCode, modifiers: binding.modifiers, isEnabled: true
    )
    if resolved.source == .userOverride {
      store.update(id, to: enabled)
    } else {
      store.clear(id)
    }
  }
}

extension ShortcutSchema.Category {
  fileprivate var title: String {
    switch self {
    case .general: return "General"
    case .projectAndWorktree: return "Project & Worktree"
    case .terminal: return "Terminal"
    case .actions: return "Actions"
    }
  }
}
