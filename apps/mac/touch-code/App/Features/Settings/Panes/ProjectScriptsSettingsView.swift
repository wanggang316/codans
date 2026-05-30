import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Scripts sub-pane. Renders every group as a sibling grouped
/// Section in one flat Form — no top-level tab switcher:
///
/// - **Setup / Archive / Delete** — git-only lifecycle script editors,
///   one body of text per phase, edited in place. Hidden when the
///   Project is a dir (no git root).
/// - **Commands** — user-defined `[ScriptDefinition]` rendered as an
///   inline, spreadsheet-style table (`ScriptCommandTable`): every field
///   is edited in place via per-cell popovers, no modal edit sheet.
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

  /// IDs for the sibling Sections; pure visibility logic lives on
  /// `visibleSections(for:)` so kind-conditional rendering is testable
  /// without the SwiftUI view tree (mirrors `ProjectGeneralSettingsView`).
  enum SectionID: String, CaseIterable, Hashable {
    case lifecycle
    case scripts
  }

  /// Lifecycle is git_repo-only; Scripts is always visible.
  nonisolated static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .dir:
      return [.scripts]
    case .gitRepo:
      return Set(SectionID.allCases)
    }
  }

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

  private var git: GitProjectSettings {
    entry?.git ?? GitProjectSettings()
  }

  private var visible: Set<SectionID> {
    Self.visibleSections(for: store.state.kind)
  }

  // MARK: - Body

  var body: some View {
    Form {
      if visible.contains(.lifecycle) {
        lifecycleSection(
          title: "Setup Script",
          subtitle: "Runs after a new worktree is created.",
          icon: "truck.box.badge.clock",
          iconColor: .blue,
          example: "pnpm install",
          text: git.createScript?.command ?? "",
          phase: .setup
        )
        lifecycleSection(
          title: "Archive Script",
          subtitle: "Runs before a worktree is archived.",
          icon: "archivebox",
          iconColor: .orange,
          example: "docker compose down",
          text: git.archiveScript?.command ?? "",
          phase: .archive
        )
        lifecycleSection(
          title: "Delete Script",
          subtitle: "Runs before a worktree is removed (files still on disk).",
          icon: "trash",
          iconColor: .red,
          example: "docker compose down",
          text: git.deleteScript?.command ?? "",
          phase: .delete
        )
      }

      if visible.contains(.scripts) {
        scriptsSection
      }

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
      return .rejected(message: "In use by script \"\(conflicting.displayName)\".")
    }
    return .ok
  }

  // MARK: - Lifecycle Section

  @ViewBuilder
  private func lifecycleSection(
    title: String,
    subtitle: String,
    icon: String,
    iconColor: Color,
    example: String,
    text: String,
    phase: SettingsWriter.WorktreeLifecycle
  ) -> some View {
    Section {
      LifecycleEditor(
        initial: text,
        onCommit: { newValue in
          store.send(.setLifecycleScript(phase, newValue))
        }
      )
    } header: {
      Label {
        VStack(alignment: .leading, spacing: 0) {
          Text(title)
            .font(.body)
            .bold()
            .lineLimit(1)
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: icon)
          .foregroundStyle(iconColor)
          .accessibilityHidden(true)
      }
      .labelStyle(.scriptSectionHeader)
    } footer: {
      Text("e.g., `\(example)`")
    }
  }

  // MARK: - Scripts Section

  /// Inline command table. The table owns no store access — every
  /// mutation routes back through the closures so writes stay on the TCA
  /// path. Row insets are zeroed so the table fills the grouped Section,
  /// which provides the card chrome seen in the design.
  @ViewBuilder
  private var scriptsSection: some View {
    Section {
      ScriptCommandTable(
        scripts: scripts,
        selectedID: $selectedScriptID,
        onUpdate: updateScript,
        onAdd: addScript,
        onDelete: deleteScript,
        onReorder: reorderScript,
        validateChord: { binding, excluding in
          chordValidator(binding, excludingScriptID: excluding)
        }
      )
      .listRowInsets(EdgeInsets())
    } footer: {
      Text("Click cells to edit icon, name, command, and shortcut inline.")
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

  /// Reorder via drag-drop. Source script is removed and re-inserted at
  /// the target row's index (above-the-target).
  private func reorderScript(source: UUID, target: UUID) {
    guard source != target,
      let sourceIndex = scripts.firstIndex(where: { $0.id == source }),
      let targetIndex = scripts.firstIndex(where: { $0.id == target })
    else { return }
    var updated = scripts
    let moved = updated.remove(at: sourceIndex)
    let insertIndex = min(max(targetIndex, 0), updated.count)
    updated.insert(moved, at: insertIndex)
    store.send(.setProjectScripts(updated))
  }
}

// MARK: - Section header label style (used by the lifecycle scripts only)

private struct ScriptSectionHeaderLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

extension LabelStyle where Self == ScriptSectionHeaderLabelStyle {
  fileprivate static var scriptSectionHeader: ScriptSectionHeaderLabelStyle { .init() }
}

// MARK: - Lifecycle inline editor

/// Tiny TextEditor wrapper that commits the user's edit to the writer
/// on each change. Per-keystroke calls are safe: the writer routes
/// through `SettingsStore.scheduleSave`, which cancels and re-arms a
/// debounced disk write so a burst of keystrokes only triggers a
/// single `AtomicFileStore.write` once typing settles.
private struct LifecycleEditor: View {
  let initial: String
  let onCommit: (String) -> Void

  var body: some View {
    PlainCommandEditor(
      text: Binding(
        get: { initial },
        set: { newValue in
          if newValue != initial {
            onCommit(newValue)
          }
        }
      )
    )
    .frame(height: 90)
  }
}
