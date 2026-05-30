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

  // MARK: - Body

  var body: some View {
    Form {
      scriptsSection

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
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

  // MARK: - Commands Section

  /// Inline command table. The table owns no store access — every
  /// mutation routes back through the closures so writes stay on the TCA
  /// path. The grouped Section supplies the card chrome; the table draws
  /// its own clipped header + rows block, add/remove bar, and hint.
  @ViewBuilder
  private var scriptsSection: some View {
    Section {
      ScriptCommandTable(
        scripts: scripts,
        selectedID: $selectedScriptID,
        onUpdate: updateScript,
        onAdd: addScript,
        onDelete: deleteScript,
        validateChord: { binding, excluding in
          chordValidator(binding, excludingScriptID: excluding)
        }
      )
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Commands")
        Text("Repository-local terminal actions. Command shortcuts take precedence in this repository.")
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Mutations

  /// Append a fresh custom command and select it. Defaults to the
  /// `.custom` kind (the only kind the inline table creates) with a
  /// unique-ish placeholder name the user edits in place.
  private func addScript() {
    let new = ScriptDefinition(kind: .custom, name: "Command \(scripts.count + 1)")
    store.send(.setProjectScripts(scripts + [new]))
    selectedScriptID = new.id
  }

  private func updateScript(_ script: ScriptDefinition) {
    var updated = scripts
    guard let index = updated.firstIndex(where: { $0.id == script.id }) else { return }
    updated[index] = script
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
