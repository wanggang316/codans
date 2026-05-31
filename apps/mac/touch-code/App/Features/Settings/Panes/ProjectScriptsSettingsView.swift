import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Commands sub-pane — the user-defined `[ScriptDefinition]`
/// rendered as an inline, spreadsheet-style table (`ScriptCommandTable`):
/// every field is edited in place via per-cell popovers, no modal sheet.
///
/// Worktree-lifecycle scripts (Setup / Archive / Delete) live at the bottom
/// of the General pane, not here.
///
/// Reads come from `@Environment(SettingsStore.self)` for live updates;
/// writes always go through the TCA reducer so test stores can spy on
/// individual writes without instantiating the SwiftUI view.
struct ProjectScriptsSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  @Environment(SettingsStore.self) private var settingsStore
  /// Resolved system-shortcut map. Drives chord-conflict detection
  /// against every registered CommandID at recording time.
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts: ResolvedShortcutMap

  /// Currently selected command row in the inline table. Drives the
  /// row highlight and the `−` (remove) button. Lifted out of the table
  /// so `addScript()` can select the freshly-created row.
  @State private var selectedScriptID: UUID?

  // MARK: - Derived state

  private var entry: ProjectSettings? {
    settingsStore.settings.projects[projectID]
  }

  private var scripts: [ScriptDefinition] {
    entry?.scripts ?? []
  }

  /// What the table renders. A Project with no Run command of its own always
  /// shows the built-in Run as a starting default; it materializes into
  /// `scripts` (via `updateScript`) the first time the user edits it.
  private var displayedScripts: [ScriptDefinition] {
    if scripts.contains(where: { $0.kind == .run }) {
      return scripts
    }
    return [.builtinRun] + scripts
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Label(error, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
      }

      ScriptCommandTable(
        scripts: displayedScripts,
        selectedID: $selectedScriptID,
        onUpdate: updateScript,
        onAdd: addScript,
        onDelete: deleteScript,
        onMove: moveScript,
        validateChord: { binding, excluding in
          chordValidator(binding, excludingScriptID: excluding)
        }
      )
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Reject reserved / conflicting chords at recording time. Order
  /// mirrors the Settings → Shortcuts pane: macOS system reservations
  /// first, then AppKit standard menus, then the app's own registered
  /// CommandIDs, then sibling scripts in this Project.
  private func chordValidator(
    _ binding: ShortcutBinding,
    excludingScriptID: UUID
  ) -> HotkeyRecorderPopover.ValidationResult {
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
    // InternalConflictDetector takes a CommandID to exclude (the row
    // being edited in the Shortcuts pane). Scripts aren't in the
    // schema and don't have a CommandID, so we walk the resolved
    // map directly — no exclusion needed.
    if let conflictingID = resolvedShortcuts.first(where: { _, resolved in
      guard let bound = resolved.binding, bound.isEnabled else { return false }
      return bound.keyCode == binding.keyCode && bound.modifiers == binding.modifiers
    })?.key {
      let label = ShortcutSchema.app.entry(for: conflictingID)?.title ?? "another command"
      return .rejected(message: "In use by \(label).")
    }
    if let conflicting = scripts.first(where: { sibling in
      sibling.id != excludingScriptID
        && sibling.keyboardShortcut?.keyCode == binding.keyCode
        && sibling.keyboardShortcut?.modifiers == binding.modifiers
    }) {
      return .rejected(message: "In use by command \"\(conflicting.displayName)\".")
    }
    return .ok
  }

  // MARK: - Mutations

  /// Append a command of the chosen kind and select it. Custom commands get a
  /// unique-ish placeholder name; predefined kinds fall back to their kind
  /// name (`displayName`) so the row reads "Run", "Test", etc. until renamed.
  private func addScript(kind: ScriptKind) {
    let name = kind == .custom ? "Command \(scripts.count + 1)" : ""
    let new = ScriptDefinition(kind: kind, name: name)
    store.send(.setProjectScripts(scripts + [new]))
    selectedScriptID = new.id
  }

  /// Move a command up (`offset == -1`) or down (`offset == 1`) by swapping it
  /// with its neighbour. Out-of-range moves are ignored.
  private func moveScript(id: UUID, offset: Int) {
    guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard target >= 0, target < scripts.count else { return }
    var updated = scripts
    updated.swapAt(index, target)
    store.send(.setProjectScripts(updated))
  }

  private func updateScript(_ script: ScriptDefinition) {
    var updated = scripts
    if let index = updated.firstIndex(where: { $0.id == script.id }) {
      updated[index] = script
    } else {
      // First edit of the virtual built-in Run: materialize it at the front
      // so it keeps the position it occupied while still a default.
      updated.insert(script, at: 0)
    }
    store.send(.setProjectScripts(updated))
  }

  private func deleteScript(id: UUID) {
    guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
    var updated = scripts
    updated.remove(at: index)
    store.send(.setProjectScripts(updated))
    // Keep a sensible row selected after removal so the `−` button and
    // highlight don't dangle on a deleted id.
    if selectedScriptID == id {
      selectedScriptID = updated.isEmpty ? nil : updated[min(index, updated.count - 1)].id
    }
  }
}
