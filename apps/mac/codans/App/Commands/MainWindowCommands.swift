import AppKit
import ComposableArchitecture
import SwiftUI
import CodansCore

/// Main-window menu commands, organised into standard macOS menus instead of
/// piling everything into File:
///
/// - **Codans** (app menu): Check for Updates…, next to About / Settings.
/// - **File**: project / worktree creation (Open Project…, Clone Repository…,
///   New Worktree…) — mirroring the sidebar's "Add Project" menu.
/// - **View**: sidebar chrome (Toggle Sidebar, Reveal in Sidebar) plus the
///   **Command Palette**.
/// - **Window**: the auto-populated window list ("Codans" / "Settings" window
///   entries) is dropped — codans is a single-main-window host, so switching
///   between window-title entries is noise. Those entries are AppKit-owned
///   (`addWindowsItem`), which `CommandGroup(replacing: .windowList)` does not
///   suppress, so each scene excludes its own window at the AppKit level (see
///   `ExcludeFromWindowsMenu` wired in `CodansApp.body`).
/// - **Worktree**: worktree navigation + actions, the Git Viewer toggle, and
///   the user-defined Project + Global **commands** (merged in at the bottom).
/// - **Tab**: tab lifecycle (New Tab / Close Tab) plus pane split / focus /
///   rename / switch.
///
/// Every built-in chord is sourced from the shortcut registry
/// (`ShortcutSchema.app` ⊕ `ShortcutsStore.overrides`) via the
/// `appKeyboardShortcut` modifier — defaults match what was previously
/// hardcoded inline, and a user can rebind any of them via Settings →
/// Shortcuts with the menu rebinding without restart. User-defined command
/// chords come straight off each `ScriptDefinition.keyboardShortcut`.
///
/// Registering command chords here (menu-bar keyEquivalents) is load-bearing,
/// not cosmetic: during normal use a Ghostty terminal pane holds
/// first-responder and swallows key events before any in-view
/// `.keyboardShortcut` can match them. AppKit checks menu-bar keyEquivalents
/// *ahead* of responder-chain dispatch, so the menu bar is the only place a
/// command chord fires while the terminal is focused.
///
/// `store` is a closure rather than the resolved `Store` because this `Commands`
/// struct is instantiated once at scene build, before `AppState.bringUp()` has
/// produced the live store. Reading the store lazily on each button press lets
/// the parent render `MainWindowCommands` unconditionally — see the matching
/// note in `CodansApp.body`.
///
/// Collision notes for the registry-default chords below:
///
/// - `Open PR on GitHub` lives on `⌘⌃G` rather than `⌘⇧G` so it doesn't shadow
///   AppKit's default "Find Previous" chord in editable-text contexts (Settings
///   panes, palette query, hotkey recorder, etc.).
/// - `Open Project on GitHub` (HAN-58) takes `⌘⇧G`. This intentionally shadows
///   AppKit's "Find Previous": codans's text-input surfaces don't expose Find
///   Next/Previous, so the cost is nil and the chord pairs naturally with `⌘G`
///   ("Toggle Git Viewer") + `⌘⌃G` ("Open PR on GitHub").
/// - The app delegate guards `⌘Q` quit with a confirmation when running terminal
///   sessions exist. The chord itself is the standard AppKit one and is not
///   registered with the shortcut registry — quitting is a system-level action.
struct MainWindowCommands: Commands {
  let store: () -> StoreOf<RootFeature>?
  /// Snapshot of the live `ShortcutsStore.resolved` map. Re-injected from
  /// `CodansApp.body` on every render; SwiftUI's `Commands` participates in
  /// observation, so an override rebinds the menu items without a manual refresh.
  let shortcuts: ResolvedShortcutMap
  /// First-responder tracker for sidebar focus. Drives `.disabled` on the
  /// destructive worktree chords (`⌘⌫` Archive / `⌘⇧⌫` Delete) so they only fire
  /// while the sidebar holds focus — when a Ghostty terminal pane is focused the
  /// menu items are disabled and the chord falls through to the terminal (where
  /// `⌘⌫` is the standard "delete to start of line" binding).
  let sidebarFocus: SidebarFocusObserver
  /// Source for the user-defined command rows merged into the **Worktree** menu.
  /// Read in the menu body so an add / edit / delete / reorder in Settings
  /// reflects without restart (`@Observable`; `Commands` participates in
  /// observation).
  let settingsStore: SettingsStore
  /// Live run/stop state for the command rows — a running command's row becomes
  /// "Stop …" and gates the ⌘. stop item so it doesn't swallow the terminal's
  /// ⌘. while idle. `@Observable`, same source as the tab busy spinner.
  let hierarchyManager: HierarchyManager

  var body: some Commands {
    // MARK: Codans (app menu) — Check for Updates
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        store()?.send(.checkForUpdatesRequested)
      }
      .appKeyboardShortcut(.checkForUpdates, in: shortcuts)
      .disabled(store() == nil)
    }

    // MARK: File — create
    // The sidebar's "Add Project" is itself a two-item menu; surface both items
    // flat here. "Open Project…" is the folder picker (bound to `.addProject`);
    // "Clone Repository…" opens the clone sheet.
    CommandGroup(after: .newItem) {
      Button("Open Project…") {
        store()?.send(.sidebar(.toolbarAddProjectTapped))
      }
      .appKeyboardShortcut(.addProject, in: shortcuts)
      .disabled(store() == nil)

      // No registry chord — clone is an infrequent setup action.
      Button("Clone Repository…") {
        store()?.send(.sidebar(.cloneRepoTapped))
      }
      .disabled(store() == nil)

      Button("New Worktree…") {
        store()?.send(.newWorktreeForCurrentProjectRequested)
      }
      .appKeyboardShortcut(.newWorktree, in: shortcuts)
      .disabled(!hasCurrentProject)
    }

    // MARK: View — show / hide chrome + Command Palette
    CommandGroup(after: .sidebar) {
      Button("Toggle Sidebar") {
        guard let s = store() else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          _ = s.send(.toggleSidebarRequested)
        }
      }
      .appKeyboardShortcut(.toggleSidebar, in: shortcuts)
      .disabled(store() == nil)

      Button("Reveal in Sidebar") {
        store()?.send(.revealCurrentWorktreeInSidebarRequested)
      }
      .appKeyboardShortcut(.revealCurrentWorktreeInSidebar, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Command Palette") {
        store()?.send(.commandPaletteToggle(nil))
      }
      .appKeyboardShortcut(.commandPaletteToggle, in: shortcuts)
      .disabled(store() == nil)

      // Trailing separator isolates Command Palette into its own section so the
      // system-inserted "Enter Full Screen" (which carries a leading icon) lands
      // in a separate section. macOS reserves an icon column per section, so
      // without this Command Palette would share Enter Full Screen's section and
      // get indented to clear that column — misaligning it from the items above.
      Divider()
    }

    // MARK: Worktree — navigation + actions + Git Viewer + user commands
    CommandMenu("Worktree") {
      Button("Open in Editor") {
        store()?.send(.openDefaultForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.openInEditor, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Reveal in Finder") {
        store()?.send(.revealCurrentWorktreeInFinderRequested)
      }
      .appKeyboardShortcut(.revealCurrentWorktreeInFinder, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Copy Worktree Path") {
        store()?.send(.copyCurrentWorktreePathRequested)
      }
      .appKeyboardShortcut(.copyCurrentWorktreePath, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      // Git Viewer moved here from View — it operates on the current Worktree's
      // diff and reads naturally alongside the GitHub items.
      Button("Toggle Git Viewer") {
        store()?.send(.diffInspectorToggledForCurrentWorktree)
      }
      .appKeyboardShortcut(.toggleDiffInspector, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Open PR on GitHub") {
        store()?.send(.openCurrentPRRequested)
      }
      .appKeyboardShortcut(.openCurrentPR, in: shortcuts)
      .disabled(!hasPRForCurrentWorktree)

      Button("Open Project on GitHub") {
        store()?.send(.openCurrentProjectOnGitHubRequested)
      }
      .appKeyboardShortcut(.openProjectOnGitHub, in: shortcuts)
      .disabled(!hasCurrentProject)

      Divider()

      Button("Select Previous Worktree") {
        store()?.send(.selectAdjacentWorktreeRequested(.previous))
      }
      .appKeyboardShortcut(.selectPreviousWorktree, in: shortcuts)
      .disabled(store() == nil)

      Button("Select Next Worktree") {
        store()?.send(.selectAdjacentWorktreeRequested(.next))
      }
      .appKeyboardShortcut(.selectNextWorktree, in: shortcuts)
      .disabled(store() == nil)

      Button("Back") {
        store()?.send(.worktreeHistoryBackRequested)
      }
      .appKeyboardShortcut(.worktreeHistoryBack, in: shortcuts)
      .disabled(!hasHistoryBack)

      Button("Forward") {
        store()?.send(.worktreeHistoryForwardRequested)
      }
      .appKeyboardShortcut(.worktreeHistoryForward, in: shortcuts)
      .disabled(!hasHistoryForward)

      Divider()

      // Archive / Delete are gated on `sidebarFocus.isSidebarFocused` so the
      // chord (`⌘⌫` / `⌘⇧⌫`) only fires while the sidebar holds first-responder.
      // When a Ghostty pane is focused the menu item is disabled, the menu's
      // chord matcher skips it, and the keystroke reaches the terminal —
      // preserving the standard `⌘⌫` "delete to start of line" binding.
      Button("Archive Worktree") {
        store()?.send(.archiveCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.archiveCurrentWorktree, in: shortcuts)
      .disabled(!hasActiveWorktree || !sidebarFocus.isSidebarFocused)

      Button("Delete Worktree") {
        store()?.send(.deleteCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.deleteCurrentWorktree, in: shortcuts)
      .disabled(!hasActiveWorktree || !sidebarFocus.isSidebarFocused)

      Button("Show Archived Worktrees") {
        store()?.send(.showArchivedWorktreesForCurrentProjectRequested)
      }
      .appKeyboardShortcut(.showArchivedWorktrees, in: shortcuts)
      .disabled(!hasCurrentProject)

      Divider()

      // User-defined Project + Global commands, merged in from the former
      // standalone "Commands" menu.
      commandsMenuContent()
    }

    // MARK: Tab — tab / pane management
    CommandMenu("Tab") {
      Button("New Tab") {
        store()?.send(.newTabForCurrentWorktree)
      }
      .appKeyboardShortcut(.newTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Close Tab") {
        // ⌘W is a global menu chord; SwiftUI Commands aren't scene-scoped, so the
        // same accelerator fires regardless of which window is key. Route on the
        // current key window: Settings (or any future SwiftUI utility window
        // tagged via `SettingsWindowTagger`) closes itself; the main `codans`
        // window forwards to TabFeature. Without this dispatch the chord pressed
        // inside Settings would close the foreground worktree's tab.
        if let key = NSApp.keyWindow, SettingsWindowTagger.matches(key) {
          key.performClose(nil)
        } else {
          store()?.send(.closeActiveTabForCurrentWorktree)
        }
      }
      .appKeyboardShortcut(.closeTab, in: shortcuts)
      .disabled(store() == nil)

      Divider()

      Button("Split Right") {
        store()?.send(.splitCurrentPaneRequested(direction: .right))
      }
      .appKeyboardShortcut(.splitRight, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Split Down") {
        store()?.send(.splitCurrentPaneRequested(direction: .down))
      }
      .appKeyboardShortcut(.splitDown, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Focus Pane Left") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .left))
      }
      .appKeyboardShortcut(.focusSplitLeft, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Pane Right") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .right))
      }
      .appKeyboardShortcut(.focusSplitRight, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Pane Up") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .up))
      }
      .appKeyboardShortcut(.focusSplitUp, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Pane Down") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .down))
      }
      .appKeyboardShortcut(.focusSplitDown, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Rename Tab…") {
        store()?.send(.renameActiveTabForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.renameActiveTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Change Tab Color…") {
        store()?.send(.changeActiveTabColorForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.changeActiveTabColor, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Previous Tab") {
        store()?.send(.selectAdjacentTabForCurrentWorktree(.previous))
      }
      .appKeyboardShortcut(.previousTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Next Tab") {
        store()?.send(.selectAdjacentTabForCurrentWorktree(.next))
      }
      .appKeyboardShortcut(.nextTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      ForEach(1...10, id: \.self) { n in
        if let id = CommandID.switchToTab(index: n) {
          Button("Switch to Tab \(n)") {
            store()?.send(.selectTabAtIndexForCurrentWorktree(n))
          }
          .appKeyboardShortcut(id, in: shortcuts)
          .disabled(!hasActiveWorktree)
        }
      }
    }
  }

  // MARK: - Commands menu content

  /// Builds the user-defined command rows merged into the **Worktree** menu:
  /// every Project command for the current Worktree's Project, then every Global
  /// command, then a fixed ⌘. stop item and the two "Manage …" footers. A
  /// running command's row flips to "Stop …". Plain function (not
  /// `@ViewBuilder`) so the `let` bindings that gather the command lists are
  /// legal; the returned `Group` body is the view tree.
  private func commandsMenuContent() -> some View {
    let projectID = store()?.state.selection.projectID
    let worktreeID = store()?.state.selection.worktreeID
    let projectScripts = projectID.flatMap { settingsStore.settings.projects[$0]?.scripts } ?? []
    let globalScripts = settingsStore.settings.general.globalScripts
    let allScripts = projectScripts + globalScripts
    // Either list can hold the command currently running in this worktree; ⌘.
    // targets whichever it is.
    let runningScriptID = worktreeID.flatMap { wid in
      allScripts.first { hierarchyManager.isScriptRunning(worktreeID: wid, scriptID: $0.id) }?.id
    }

    return Group {
      ForEach(projectScripts) { script in
        scriptButton(for: script, isGlobal: false, worktreeID: worktreeID)
      }
      if !projectScripts.isEmpty, !globalScripts.isEmpty {
        Divider()
      }
      ForEach(globalScripts) { script in
        scriptButton(for: script, isGlobal: true, worktreeID: worktreeID)
      }

      if !allScripts.isEmpty {
        Divider()
      }

      // ⌘. interrupts whatever command is currently running in this worktree —
      // the standard macOS "cancel" chord. Disabled while idle so it doesn't
      // swallow ⌘. that should reach a focused terminal pane.
      Button("Stop Command") {
        if let runningScriptID {
          store()?.send(.stopScriptForCurrentWorktree(scriptID: runningScriptID))
        }
      }
      .keyboardShortcut(".", modifiers: .command)
      .disabled(runningScriptID == nil)

      Divider()

      Button("Manage Project Commands…") {
        if let projectID = store()?.state.selection.projectID {
          store()?.send(.worktreeHeader(.delegate(.manageScriptsRequested(projectID: projectID))))
        }
      }
      .disabled(!hasCurrentProject)

      Button("Manage Global Commands…") {
        store()?.send(.worktreeHeader(.delegate(.manageGlobalScriptsRequested)))
      }
    }
  }

  /// One command row. `isGlobal` routes the run dispatch through the global run
  /// path; project commands use the project run path. A running command flips to
  /// "Stop …" and toggles via the shared stop path. The chord comes straight off
  /// `ScriptDefinition.keyboardShortcut` (registered as a menu-bar keyEquivalent
  /// so it fires while the terminal is focused).
  @ViewBuilder
  private func scriptButton(
    for script: ScriptDefinition, isGlobal: Bool, worktreeID: WorktreeID?
  ) -> some View {
    let isRunning =
      worktreeID.map {
        hierarchyManager.isScriptRunning(worktreeID: $0, scriptID: script.id)
      } ?? false
    Button(isRunning ? "Stop \(script.displayName)" : "Run \(script.displayName)") {
      if isRunning {
        store()?.send(.stopScriptForCurrentWorktree(scriptID: script.id))
      } else if isGlobal {
        store()?.send(.runGlobalScriptForCurrentWorktree(scriptID: script.id))
      } else {
        store()?.send(.runScriptForCurrentWorktree(scriptID: script.id))
      }
    }
    .modifier(ScriptChordModifier(binding: script.keyboardShortcut))
    .disabled(!hasActiveWorktree)
  }

  // MARK: - Enablement

  private var hasActiveWorktree: Bool {
    store()?.state.selection.worktreeID != nil
  }

  /// `true` when the current Worktree has a PR snapshot in the GitHub feature's
  /// cache. Drives `.disabled` of "Open PR on GitHub" — a Worktree without a
  /// fetched PR (non-GitHub repo, fresh branch, auth not configured) silently
  /// exposes a useless chord otherwise.
  private var hasPRForCurrentWorktree: Bool {
    guard
      let worktreeID = store()?.state.selection.worktreeID,
      store()?.state.gitHub.snapshots[worktreeID] != nil
    else { return false }
    return true
  }

  /// Drive `.disabled` on Back/Forward so the chord is a hard no-op (and dims
  /// the menu item) when there's no entry to navigate to.
  private var hasHistoryBack: Bool {
    !(store()?.state.navigationHistoryBack.isEmpty ?? true)
  }

  private var hasHistoryForward: Bool {
    !(store()?.state.navigationHistoryForward.isEmpty ?? true)
  }

  /// `true` when there is a selected Project. Drives `.disabled` for
  /// "New Worktree…" / "Manage Project Commands…". Doesn't gate on `gitRoot`
  /// (non-git Project ⇒ chord silently no-ops in the reducer) because reading a
  /// `HierarchyManager` snapshot inside SwiftUI `Commands` resolves against
  /// `liveValue` and crashes (PR-#13 trap). The reducer's guard is sufficient.
  private var hasCurrentProject: Bool {
    store()?.state.selection.projectID != nil
  }
}

/// Conditionally applies a `ScriptDefinition`'s chord to a command's menu item.
/// Short-circuits — returns the content unchanged — when the binding is absent,
/// disabled, has a zero keyCode, or has no matching `KeyEquivalent`.
private struct ScriptChordModifier: ViewModifier {
  let binding: ShortcutBinding?

  func body(content: Content) -> some View {
    if let binding, binding.isEnabled, binding.keyCode != 0,
      let key = ShortcutDisplay.keyEquivalent(for: binding.keyCode)
    {
      content.keyboardShortcut(key, modifiers: ShortcutDisplay.eventModifiers(for: binding.modifiers))
    } else {
      content
    }
  }
}
