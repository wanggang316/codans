import ComposableArchitecture
import SwiftUI
import CodansCore

/// Mounts an invisible Button per project-script chord so the shortcut
/// lives in the window's responder chain regardless of whether the
/// run-script Menu in the toolbar has been opened.
///
/// Lives **outside** the toolbar on purpose: SwiftUI converts toolbar
/// content into an `NSToolbarItem` and only exports the visible control's
/// keyEquivalent to the window's responder chain. A 0×0 Button mounted as
/// `.background` of the toolbar Menu therefore never participates in
/// chord dispatch. Mounting the bindings on the detail body sidesteps that
/// by keeping the buttons in the regular SwiftUI view tree.
struct ProjectScriptsShortcutBindings: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  /// Project whose scripts contribute chords. Worktree resolution is
  /// deferred to `RootFeature` (reads `state.selection` at handle-time);
  /// this view does not need to know which Worktree is active.
  let projectID: ProjectID
  /// Selected worktree — needed only to resolve which script is currently
  /// running so the ⌘. "stop" chord can target it. The per-script run chords
  /// stay worktree-agnostic (RootFeature resolves their target from selection).
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let scripts = settingsStore.settings.projects[projectID]?.scripts ?? []
    ForEach(scripts) { script in
      shadow(for: script)
    }
    stopChord(scripts: scripts)
  }

  /// ⌘. interrupts the run-script currently executing in this worktree — the
  /// standard macOS "cancel" chord. Mounted only while something is running so
  /// it doesn't swallow ⌘. when idle. Reuses `stopScriptTapped`; RootFeature
  /// resolves the worktree from selection at handle-time like the run path.
  @ViewBuilder
  private func stopChord(scripts: [ScriptDefinition]) -> some View {
    if let running = scripts.first(where: {
      hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: $0.id)
    }) {
      Button {
        store.send(.stopScriptTapped(scriptID: running.id))
      } label: {
        EmptyView()
      }
      .keyboardShortcut(".", modifiers: .command)
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func shadow(for script: ScriptDefinition) -> some View {
    if let chord = script.keyboardShortcut, chord.isEnabled, chord.keyCode != 0,
      let key = ShortcutDisplay.keyEquivalent(for: chord.keyCode)
    {
      Button {
        store.send(.runScriptTapped(scriptID: script.id))
      } label: {
        EmptyView()
      }
      .keyboardShortcut(key, modifiers: ShortcutDisplay.eventModifiers(for: chord.modifiers))
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
    }
  }
}
