import CodansCore
import ComposableArchitecture
import SwiftUI

/// Toolbar split button: the primary half runs the Project's first script
/// (whichever the user has dragged to index 0 in Settings → Project Commands);
/// the chevron half opens the command dropdown — Project and Global commands,
/// the Config Files section (commands detected in the worktree's manifests),
/// and the two "Manage …" footers. Empty state: the primary click opens
/// Manage Project Commands so users land where they can create one.
///
/// Rendered by `RunSplitButton` (AppKit) rather than SwiftUI's `Menu`: the
/// dropdown's taller rows and per-row add accessory need view-backed menu
/// items. Every action dispatches through `WorktreeHeaderFeature.delegate`
/// so `RootFeature` owns the run effects.
struct HeaderRunScriptSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  /// Project whose script list the dropdown enumerates. The active
  /// Worktree is intentionally NOT stored on this view: the chord +
  /// menu dispatch goes through `RootFeature` which resolves the
  /// target Worktree from `state.selection` at handle-time, sidestepping
  /// stale NSMenuItem closure captures on worktree switch.
  let projectID: ProjectID
  /// Selected Worktree, used *only* to read the live Run/Stop state for this
  /// view (`HierarchyManager.isScriptRunning`). Dispatch still routes
  /// scriptID-only through `RootFeature`, which re-resolves the worktree from
  /// `state.selection` at handle-time — so this read-only capture cannot fire
  /// a script against the wrong worktree. The view is rebuilt per resolved
  /// address, so the value tracks the live selection.
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore
  /// Live busy state for the Run/Stop toggle. `@Observable`, so reads in
  /// `body` re-render the button when a run pane starts/stops executing —
  /// same source the tab busy spinner reads.
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    // Read in body so Observation re-renders the button when the primary
    // script changes; the dropdown reads its own live state when it opens.
    let scripts = settingsStore.settings.projects[projectID]?.scripts ?? []
    // Primary is whichever script the user has placed at index 0
    // in the Settings → Project Scripts list. Drag-to-reorder is
    // the only knob the user has — preferring `.run` kind over
    // position would silently undo their manual reorder.
    let primary = scripts.first
    let primaryName = primary?.displayName ?? "Run"
    // Run/Stop toggle: while the primary script's dedicated pane is executing
    // a foreground command, the button becomes a red Stop that interrupts it
    // (Ctrl-C) instead of launching another run.
    let isRunning =
      primary.map {
        hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: $0.id)
      } ?? false
    let primaryIcon: CommandIconRef =
      isRunning ? .symbol("stop.fill") : (primary?.resolvedIcon ?? .symbol(ScriptKind.run.defaultSystemImage))
    let primaryTint =
      isRunning
      ? ScriptTintColorPalette.color(for: .red)
      : ScriptTintColorPalette.color(for: primary?.resolvedTintColor ?? .green)
    let primaryHelp =
      primary == nil
      ? "Manage Scripts…" : (isRunning ? "Stop \(primaryName)" : "Run \(primaryName)")
    // While ⌘ is held the button surfaces its chord (the macOS menu
    // convention). Idle → the primary script's configured shortcut; running →
    // the fixed ⌘. stop chord. `commandKeyHint` gates the actual display on ⌘.
    let primaryChord: String? =
      isRunning
      ? "⌘."
      : primary?.keyboardShortcut.flatMap {
        $0.isEnabled && $0.keyCode != 0 ? ShortcutDisplay.chord(for: $0) : nil
      }
    RunSplitButton(
      image: CommandIconImage.tinted(primaryIcon, color: NSColor(primaryTint), pointSize: RunMenuMetrics.iconPointSize),
      // Beside the glyph while ⌘ is held (the macOS menu convention): the
      // primary script's shortcut, or the fixed ⌘. while it runs.
      chordHint: commandKeyObserver.isCommandHeld ? primaryChord : nil,
      toolTip: primaryHelp,
      accessibilityLabel: isRunning ? "Stop \(primaryName)" : primaryName,
      onPrimary: {
        if let script = primary {
          store.send(isRunning ? .stopScriptTapped(scriptID: script.id) : .runScriptTapped(scriptID: script.id))
        } else {
          store.send(.manageScriptsTapped(projectID: projectID))
        }
      },
      makeMenu: { menuModel() }
    )
    // Only a worktree switch rescans; script edits just change what the next
    // menu open shows.
    .task(id: worktreeID) {
      store.send(.scanCommandSuggestions(projectID: projectID, worktreeID: worktreeID))
    }
  }

  // MARK: - Dropdown

  /// Built when the dropdown opens, from live state: settings, run flags and
  /// the latest scan for this worktree.
  private func menuModel() -> RunMenuModel {
    let scripts = settingsStore.settings.projects[projectID]?.scripts ?? []
    let globalScripts = settingsStore.settings.general.globalScripts
    var model = RunMenuModel()
    model.projectCommands = scripts.map { command(for: $0, isGlobal: false) }
    model.globalCommands = globalScripts.map { command(for: $0, isGlobal: true) }
    if store.commandSuggestionsWorktreeID == worktreeID {
      model.isScanning = store.isScanningCommandSuggestions && store.commandSuggestions.isEmpty
      model.configFiles = store.commandSuggestions.map { configFile(for: $0, scripts: scripts) }
      model.refresh = { [store, projectID, worktreeID] in
        store.send(.scanCommandSuggestions(projectID: projectID, worktreeID: worktreeID))
      }
    }
    model.manageProjectCommands = { [store, projectID] in store.send(.manageScriptsTapped(projectID: projectID)) }
    model.manageGlobalCommands = { [store] in store.send(.manageGlobalScriptsTapped) }
    return model
  }

  /// A running script's row becomes a red "Stop …" that interrupts it. Stop is
  /// shared by both lists: the run pane is keyed by (worktree, scriptID).
  private func command(for script: ScriptDefinition, isGlobal: Bool) -> RunMenuModel.Command {
    let isRunning = hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: script.id)
    let chord = script.keyboardShortcut.flatMap {
      $0.isEnabled && $0.keyCode != 0 ? ShortcutDisplay.chord(for: $0) : nil
    }
    return RunMenuModel.Command(
      id: script.id,
      title: isRunning ? "Stop \(script.displayName)" : script.displayName,
      icon: isRunning ? .symbol("stop.fill") : script.resolvedIcon,
      tint: NSColor(ScriptTintColorPalette.color(for: isRunning ? .red : script.resolvedTintColor)),
      chord: chord,
      perform: { [store] in
        if isRunning {
          store.send(.stopScriptTapped(scriptID: script.id))
        } else if isGlobal {
          store.send(.runGlobalScriptTapped(scriptID: script.id))
        } else {
          store.send(.runScriptTapped(scriptID: script.id))
        }
      }
    )
  }

  private func configFile(for group: CommandSuggestionGroup, scripts: [ScriptDefinition]) -> RunMenuModel.ConfigFile {
    RunMenuModel.ConfigFile(
      title: group.source.displayName,
      icon: group.suggestions.first.flatMap { CommandIconCatalog.runnerIcon(forCommand: $0.command) },
      entries: group.suggestions.map { suggestion in
        RunMenuModel.Entry(
          id: suggestion.id,
          title: suggestion.name,
          subtitle: CommandSuggestionMenuSection.subtitle(for: suggestion),
          icon: suggestion.resolvedIcon,
          tint: NSColor(ScriptTintColorPalette.color(for: suggestion.kind.defaultTintColor)),
          isAdded: CommandSuggestionAdoption.isAdopted(suggestion, in: scripts),
          run: { [store, projectID] in
            store.send(.runCommandSuggestionTapped(projectID: projectID, suggestion))
          },
          add: { [store, projectID] in
            store.send(.addCommandSuggestionTapped(projectID: projectID, suggestion))
          }
        )
      }
    )
  }
}
