import Dependencies
import Foundation
import CodansCore

/// Builds the list of `CommandPaletteItem` shown when the palette opens.
///
/// Called once per palette open (not per keystroke). The returned list is
/// filtered on every query change by `CommandPaletteFuzzyScorer`.
///
/// Items are emitted in three context bands:
///
/// 1. **Always**: app-level commands.
/// 2. **When a Worktree is selected**: Git viewer toggle, editor-open
///    commands (one per installed `EditorDescriptor`), refresh, close,
///    reveal in Finder.
/// 3. **When a Pane is focused**: all `PaneActionRequest` and
///    `WindowActionRequest` cases that require a source pane. If no
///    pane is focused, these items are omitted rather than emitted with
///    a synthetic pane ID.
enum CommandPaletteItems {
  static func build(
    selection: HierarchySelection,
    catalog: Catalog,
    editorDescriptors: [EditorDescriptor] = [],
    focusedPaneID: PaneID? = nil,
    paneFocusPrecise: Bool = false
  ) -> [CommandPaletteItem] {
    var items = appItems()
    items.append(contentsOf: worktreeSwitchItems(selection: selection, catalog: catalog))
    // Project-level maintenance commands surface whenever a Project is
    // selected, independent of whether a Worktree is also selected.
    if selection.projectID != nil {
      items.append(contentsOf: projectItems())
    }
    if let worktree = resolveWorktree(selection: selection, catalog: catalog) {
      items.append(contentsOf: worktreeItems(worktreeName: worktree.name, isPinned: worktree.isPinned))
      items.append(contentsOf: worktreeLifecycleItems(worktreeName: worktree.name))
      items.append(contentsOf: editorItems(worktreeName: worktree.name, descriptors: editorDescriptors))
      // Tab commands act on the current Worktree's active tab, so they're
      // gated on the Worktree selection rather than on precise pane focus.
      items.append(contentsOf: tabCommandItems(worktreeName: worktree.name))
      // Surface user-defined `ProjectSettings.scripts` for the active
      // Project. Reads through the SettingsWriter dependency so the palette
      // tracks the live `settings.json` snapshot — switching to a different
      // Project rebuilds and surfaces that Project's scripts instead.
      if let projectID = selection.projectID, let worktreeID = selection.worktreeID {
        items.append(
          contentsOf: projectScriptItems(projectID: projectID, worktreeID: worktreeID)
        )
        // Global commands (`general.globalScripts`) run in the selected
        // Worktree, so they're gated on the same selection as project scripts.
        items.append(
          contentsOf: globalScriptItems(projectID: projectID, worktreeID: worktreeID)
        )
      }
    }
    if let focusedPaneID {
      // Window actions only need any leaf in the current tab to resolve
      // the source NSWindow, so they're always safe once we have a
      // PaneID. Pane actions that depend on real focus (split / goto /
      // resize / zoom) are only emitted when the pane was reported by
      // the ghostty keybind path — not a fallback from leaves().first.
      items.append(contentsOf: windowItems(focusedPaneID: focusedPaneID))
      if paneFocusPrecise {
        items.append(contentsOf: paneFocusDependentItems())
      }
      items.append(contentsOf: paneTabScopedItems())
    }
    return items
  }

  /// One "Switch to Worktree" item per live Worktree across every Project,
  /// excluding the currently selected one. `subtitle` carries the Project
  /// name so the fuzzy scorer's subtitle band matches a Project-name query —
  /// typing a Project's name surfaces all of that Project's switch targets
  /// without a dedicated Project row. Archived Worktrees are omitted (they're
  /// soft-hidden from the sidebar and reachable only via the Archived sheet);
  /// deleted Worktrees never reach here because deletion drops them from the
  /// catalog.
  private static func worktreeSwitchItems(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = []
    for project in catalog.projects {
      for worktree in project.worktrees
      where worktree.id != selection.worktreeID && !worktree.archived {
        items.append(
          CommandPaletteItem(
            id: "worktree.select.\(worktree.id.raw.uuidString)",
            title: "Switch to Worktree: \(worktree.name)",
            subtitle: project.name,
            // Project name first so a Project-name query ranks high (and
            // earns the leading-position bonus); worktree name included so
            // it still matches without the decorative "Switch to Worktree:"
            // prefix that otherwise pollutes fuzzy matching.
            searchText: "\(project.name) \(worktree.name)",
            icon: "arrow.triangle.branch",
            kind: .selectWorktree(project.id, worktree.id)
          )
        )
      }
    }
    return items
  }

  private static func appItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "app.open-project",
        title: "Open Project…",
        // Scope keyword in `searchText` so a level query ("project") surfaces
        // the whole group even when the word is absent from the visible title.
        searchText: "app project",
        icon: "folder",
        commandID: .addProject,
        kind: .openProject
      ),
      CommandPaletteItem(
        id: "app.clone-repository",
        title: "Clone Repository…",
        searchText: "app project repository git",
        icon: "square.and.arrow.down.on.square",
        kind: .cloneRepository
      ),
      CommandPaletteItem(
        id: "app.open-settings",
        title: "Open Settings",
        searchText: "app",
        icon: "gearshape",
        shortcut: .command(","),
        commandID: .openSettings,
        kind: .openSettings
      ),
      CommandPaletteItem(
        id: "app.toggle-sidebar",
        title: "Toggle Sidebar",
        searchText: "app sidebar",
        icon: "sidebar.left",
        commandID: .toggleSidebar,
        kind: .toggleSidebar
      ),
      CommandPaletteItem(
        id: "app.show-unread",
        title: "Show Unread Notifications",
        searchText: "app notifications inbox",
        icon: "bell.badge",
        commandID: .showUnread,
        kind: .showUnreadNotifications
      ),
      CommandPaletteItem(
        id: "app.open-ghostty-config",
        title: "Open Ghostty Config",
        searchText: "app config settings",
        icon: "doc.badge.gearshape",
        kind: .openGhosttyConfig
      ),
      CommandPaletteItem(
        id: "app.check-for-updates",
        title: "Check for Updates…",
        searchText: "app",
        icon: "arrow.down.circle",
        commandID: .checkForUpdates,
        kind: .checkForUpdates
      ),
      CommandPaletteItem(
        id: "app.quit",
        title: "Quit Codans",
        searchText: "app",
        icon: "power",
        shortcut: .command("Q"),
        hiddenWhenQueryEmpty: true,
        kind: .quit
      ),
    ]
  }

  private static func resolveWorktree(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> Worktree? {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID
    else { return nil }
    return catalog.projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  /// Worktree-scoped commands for the current selection. Every item carries
  /// the "worktree" scope keyword in `searchText` so typing the level name
  /// surfaces the whole group, even for titles that don't contain the word
  /// (e.g. "Toggle Git Viewer", "Open PR on GitHub").
  private static func worktreeItems(
    worktreeName: String,
    isPinned: Bool
  ) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "git.toggle-viewer",
        title: "Toggle Git Viewer",
        subtitle: worktreeName,
        searchText: "worktree git diff viewer",
        icon: "doc.text.magnifyingglass",
        shortcut: .command("G", shift: true),
        commandID: .toggleDiffInspector,
        kind: .toggleDiffInspector
      ),
      CommandPaletteItem(
        id: "worktree.new",
        title: "New Worktree…",
        searchText: "worktree new create branch",
        icon: "plus.square.on.square",
        commandID: .newWorktree,
        kind: .newWorktree
      ),
      CommandPaletteItem(
        id: "editor.reveal-in-finder",
        title: "Reveal in Finder",
        subtitle: worktreeName,
        searchText: "worktree reveal finder",
        icon: "folder",
        commandID: .revealCurrentWorktreeInFinder,
        kind: .revealCurrentWorktreeInFinder
      ),
      CommandPaletteItem(
        id: "worktree.reveal-in-sidebar",
        title: "Reveal in Sidebar",
        subtitle: worktreeName,
        searchText: "worktree reveal sidebar",
        icon: "sidebar.left",
        commandID: .revealCurrentWorktreeInSidebar,
        kind: .revealCurrentWorktreeInSidebar
      ),
      CommandPaletteItem(
        id: "worktree.copy-path",
        title: "Copy Worktree Path",
        subtitle: worktreeName,
        searchText: "worktree copy path",
        icon: "doc.on.doc",
        commandID: .copyCurrentWorktreePath,
        kind: .copyCurrentWorktreePath
      ),
      CommandPaletteItem(
        id: "worktree.toggle-pin",
        title: isPinned ? "Unpin Worktree" : "Pin Worktree",
        subtitle: worktreeName,
        searchText: "worktree pin unpin",
        icon: isPinned ? "pin.slash" : "pin",
        kind: .toggleCurrentWorktreePinned
      ),
    ]
  }

  /// Second half of the worktree band — GitHub + lifecycle commands. Split
  /// from `worktreeItems` only to keep each builder under the function-length
  /// lint; emission order across the two builders is preserved.
  private static func worktreeLifecycleItems(worktreeName: String) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "worktree.open-pr",
        title: "Open PR on GitHub",
        subtitle: worktreeName,
        searchText: "worktree github pull request pr",
        icon: "arrow.up.right.square",
        commandID: .openCurrentPR,
        kind: .openCurrentPR
      ),
      CommandPaletteItem(
        id: "worktree.open-project-on-github",
        title: "Open Project on GitHub",
        searchText: "worktree project github repository",
        icon: "arrow.up.right.square",
        commandID: .openProjectOnGitHub,
        kind: .openCurrentProjectOnGitHub
      ),
      CommandPaletteItem(
        id: "worktree.refresh",
        title: "Refresh Worktree",
        subtitle: worktreeName,
        searchText: "worktree refresh reload",
        icon: "arrow.clockwise",
        kind: .refreshCurrentWorktree
      ),
      CommandPaletteItem(
        id: "worktree.show-archived",
        title: "Show Archived Worktrees",
        searchText: "worktree archived show",
        icon: "archivebox",
        commandID: .showArchivedWorktrees,
        kind: .showArchivedWorktrees
      ),
      CommandPaletteItem(
        id: "worktree.archive",
        title: "Archive Worktree",
        subtitle: worktreeName,
        searchText: "worktree archive",
        icon: "archivebox",
        commandID: .archiveCurrentWorktree,
        hiddenWhenQueryEmpty: true,
        kind: .archiveCurrentWorktree
      ),
      CommandPaletteItem(
        id: "worktree.close",
        title: "Delete Worktree",
        subtitle: worktreeName,
        searchText: "worktree delete remove",
        icon: "xmark.square",
        commandID: .deleteCurrentWorktree,
        hiddenWhenQueryEmpty: true,
        kind: .closeCurrentWorktree
      ),
    ]
  }

  /// Project-scoped commands for the current Project selection. Batch and
  /// destructive maintenance actions that were previously reachable only from
  /// the sidebar's "⋯" menu. Destructive variants are `hiddenWhenQueryEmpty`
  /// so they never surface by accident on a bare palette open.
  private static func projectItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "project.settings",
        title: "Project Settings…",
        searchText: "project settings preferences",
        icon: "slider.horizontal.3",
        kind: .openProjectSettings
      ),
      CommandPaletteItem(
        id: "project.prune-stale",
        title: "Prune Stale Worktrees",
        searchText: "project worktree prune stale clean",
        icon: "wand.and.sparkles",
        kind: .pruneStaleWorktrees
      ),
      CommandPaletteItem(
        id: "project.archive-all-merged",
        title: "Archive All Merged Worktrees",
        searchText: "project worktree archive merged batch",
        icon: "archivebox",
        hiddenWhenQueryEmpty: true,
        kind: .archiveAllMergedWorktrees
      ),
      CommandPaletteItem(
        id: "project.remove-all-merged",
        title: "Remove All Merged Worktrees",
        searchText: "project worktree remove merged batch",
        icon: "trash",
        hiddenWhenQueryEmpty: true,
        kind: .removeAllMergedWorktrees
      ),
      CommandPaletteItem(
        id: "project.remove",
        title: "Remove Project",
        searchText: "project remove delete",
        icon: "trash",
        hiddenWhenQueryEmpty: true,
        kind: .removeCurrentProject
      ),
    ]
  }

  /// Tab-scoped commands that act on the current Worktree's active tab.
  /// Gated on the Worktree selection (not pane focus) because each routes
  /// through a `…ForCurrentWorktree` action that resolves the active tab.
  private static func tabCommandItems(worktreeName: String) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "tab.rename",
        title: "Rename Tab…",
        subtitle: worktreeName,
        searchText: "tab rename",
        icon: "pencil",
        commandID: .renameActiveTab,
        kind: .renameCurrentTab
      ),
      CommandPaletteItem(
        id: "tab.change-color",
        title: "Change Tab Color…",
        subtitle: worktreeName,
        searchText: "tab color change",
        icon: "paintpalette",
        commandID: .changeActiveTabColor,
        kind: .changeCurrentTabColor
      ),
    ]
  }

  private static func editorItems(
    worktreeName: String,
    descriptors: [EditorDescriptor]
  ) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = [
      CommandPaletteItem(
        id: "editor.open-default",
        title: "Open in Editor",
        subtitle: worktreeName,
        searchText: "worktree editor open",
        icon: "arrow.up.forward.app",
        shortcut: .command("E"),
        commandID: .openInEditor,
        kind: .openCurrentWorktreeInDefaultEditor
      )
    ]
    for descriptor in descriptors {
      items.append(
        CommandPaletteItem(
          id: "editor.open.\(descriptor.id)",
          title: "Open in \(descriptor.displayName)",
          subtitle: worktreeName,
          searchText: "worktree editor open \(descriptor.displayName)",
          icon: "arrow.up.forward.app",
          kind: .openCurrentWorktreeIn(descriptor.id)
        )
      )
    }
    return items
  }

  /// Project-scoped items, one per `ProjectSettings.scripts` entry under the
  /// active Project. Pulls the script list through `SettingsWriter` so the
  /// palette mirrors live `settings.json` state without a separate cache.
  /// Subtitle uses the kind's `defaultName` ("Test", "Deploy", "Custom", …)
  /// so a user who renames a `.test` script to "Run integration suite" can
  /// still tell at a glance which kind it is.
  private static func projectScriptItems(
    projectID: ProjectID,
    worktreeID: WorktreeID
  ) -> [CommandPaletteItem] {
    @Dependency(SettingsWriter.self) var settingsWriter
    let scripts = settingsWriter.readSnapshotSync().projects[projectID]?.scripts ?? []
    return scripts.map { script in
      CommandPaletteItem(
        id: "project.script.\(projectID.raw.uuidString).\(script.id.uuidString)",
        title: script.displayName,
        subtitle: script.kind.defaultName,
        icon: script.resolvedSystemImage,
        kind: .runProjectScript(projectID, worktreeID, script.id)
      )
    }
  }

  /// Global-command items, one per `GeneralSettings.globalScripts` entry. Pulls
  /// the list through `SettingsWriter` so the palette mirrors live
  /// `settings.json` state. Carries the selection's `(projectID, worktreeID)`
  /// as the spawn target. Subtitle is fixed to "Global Command" so these are
  /// distinguishable from a same-named project command in the result list.
  /// The `id` is keyed only by the script's stable UUID (no project prefix)
  /// because a global command is the same entry regardless of which Worktree
  /// is selected.
  private static func globalScriptItems(
    projectID: ProjectID,
    worktreeID: WorktreeID
  ) -> [CommandPaletteItem] {
    @Dependency(SettingsWriter.self) var settingsWriter
    let scripts = settingsWriter.readSnapshotSync().general.globalScripts
    return scripts.map { script in
      CommandPaletteItem(
        id: "global.script.\(script.id.uuidString)",
        title: script.displayName,
        subtitle: "Global Command",
        icon: script.resolvedSystemImage,
        kind: .runGlobalScript(projectID, worktreeID, script.id)
      )
    }
  }

  /// Resolves a PaneID for palette actions opened without a precise
  /// libghostty source (menu, toolbar). Prefers the tab's last-focused
  /// pane via `lastFocusedPane` so split / focus / zoom actions anchor
  /// where the user actually is; falls back to the first leaf when no
  /// pane has been focused since the tab was selected. The first-leaf
  /// fallback is still safe for Window-scoped actions because every
  /// leaf in a tab maps to the same NSWindow.
  static func resolveFocusedPaneID(
    selection: HierarchySelection,
    catalog: Catalog,
    lastFocusedPane: (TabID) -> PaneID? = { _ in nil }
  ) -> PaneID? {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let project = catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let selectedTabID = worktree.selectedTabID,
      let tab = worktree.tabs.first(where: { $0.id == selectedTabID })
    else { return nil }
    return lastFocusedPane(selectedTabID) ?? tab.splitTree.leaves().first
  }

  // MARK: - Private builders

  /// Tab-scoped Pane actions: any pane in the current tab resolves to
  /// the same Tab via `addressOf`, so fallback-resolved paneIDs are
  /// sufficient. Safe to emit regardless of whether focus was precise.
  private static func paneTabScopedItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "pane.new-tab",
        title: "New Tab",
        searchText: "tab new",
        icon: "plus.rectangle.on.rectangle",
        kind: .paneAction(.newTab)
      ),
      CommandPaletteItem(
        id: "pane.equalize",
        title: "Equalize Splits",
        searchText: "pane split equalize",
        icon: "rectangle.split.3x1",
        kind: .paneAction(.equalizeSplits)
      ),
      CommandPaletteItem(
        id: "pane.close-tab",
        title: "Close Tab",
        searchText: "tab close",
        icon: "xmark.circle",
        hiddenWhenQueryEmpty: true,
        kind: .paneAction(.closeTab(mode: .this))
      ),
      CommandPaletteItem(
        id: "pane.close-other-tabs",
        title: "Close Other Tabs",
        searchText: "tab close other",
        icon: "xmark.circle",
        hiddenWhenQueryEmpty: true,
        kind: .paneAction(.closeTab(mode: .other))
      ),
      CommandPaletteItem(
        id: "pane.close-tabs-to-right",
        title: "Close Tabs to the Right",
        searchText: "tab close right",
        icon: "xmark.circle",
        hiddenWhenQueryEmpty: true,
        kind: .paneAction(.closeTab(mode: .right))
      ),
    ]
  }

  /// Pane actions whose target depends on which split is focused —
  /// splits, focus navigation, zoom toggle. Only emitted when the pane
  /// was carried in via the ghostty keybind pipeline (precise focus).
  /// A menu-triggered palette open omits these so the user never sees a
  /// "Focus Pane Left" that would silently navigate from the wrong
  /// pane.
  private static func paneFocusDependentItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "pane.split.right",
        title: "Split Right",
        searchText: "pane split right",
        icon: "rectangle.split.2x1",
        kind: .paneAction(.newSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "pane.split.down",
        title: "Split Down",
        searchText: "pane split down",
        icon: "rectangle.split.1x2",
        kind: .paneAction(.newSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "pane.focus.left",
        title: "Focus Pane Left",
        searchText: "pane focus left",
        icon: "arrow.left",
        kind: .paneAction(.gotoSplit(direction: .left))
      ),
      CommandPaletteItem(
        id: "pane.focus.right",
        title: "Focus Pane Right",
        searchText: "pane focus right",
        icon: "arrow.right",
        kind: .paneAction(.gotoSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "pane.focus.up",
        title: "Focus Pane Up",
        searchText: "pane focus up",
        icon: "arrow.up",
        kind: .paneAction(.gotoSplit(direction: .up))
      ),
      CommandPaletteItem(
        id: "pane.focus.down",
        title: "Focus Pane Down",
        searchText: "pane focus down",
        icon: "arrow.down",
        kind: .paneAction(.gotoSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "pane.toggle-zoom",
        title: "Toggle Split Zoom",
        searchText: "pane split zoom",
        icon: "plus.magnifyingglass",
        kind: .paneAction(.toggleSplitZoom)
      ),
      CommandPaletteItem(
        id: "pane.close",
        title: "Close Pane",
        searchText: "pane close",
        icon: "xmark.square",
        hiddenWhenQueryEmpty: true,
        kind: .paneAction(.closePane)
      ),
    ]
  }

  /// Window-scoped commands. `New Window` and `Show Tab Overview` were
  /// removed: codans runs a single-instance `Window(id:)` scene (see
  /// `CodansApp.body`), so `WindowService.openNewWindow` is a logged no-op and
  /// `NSWindow.toggleTabOverview` has no native window-tab group to act on —
  /// both surfaced as dead palette rows. `Close Window` and `Toggle
  /// Fullscreen` map onto real AppKit calls and stay.
  private static func windowItems(focusedPaneID: PaneID) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "window.toggle-fullscreen",
        title: "Toggle Fullscreen",
        searchText: "window fullscreen",
        icon: "arrow.up.left.and.arrow.down.right",
        kind: .windowAction(.toggleFullscreen(from: focusedPaneID))
      ),
      CommandPaletteItem(
        id: "window.close",
        title: "Close Window",
        searchText: "window close",
        icon: "xmark",
        hiddenWhenQueryEmpty: true,
        kind: .windowAction(.close(from: focusedPaneID))
      ),
    ]
  }
}
