import Dependencies
import Foundation
import TouchCodeCore

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
    if let worktree = resolveWorktree(selection: selection, catalog: catalog) {
      items.append(contentsOf: worktreeItems(worktreeName: worktree.name))
      items.append(contentsOf: editorItems(worktreeName: worktree.name, descriptors: editorDescriptors))
      // M10: surface user-defined `ProjectSettings.scripts` for the active
      // Project. Reads through the SettingsWriter dependency so the palette
      // tracks the live `settings.json` snapshot — switching to a different
      // Project rebuilds and surfaces that Project's scripts instead.
      if let projectID = selection.projectID, let worktreeID = selection.worktreeID {
        items.append(
          contentsOf: projectScriptItems(projectID: projectID, worktreeID: worktreeID)
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

  private static func worktreeSwitchItems(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = []
    for project in catalog.projects {
      for worktree in project.worktrees where worktree.id != selection.worktreeID {
        items.append(
          CommandPaletteItem(
            id: "worktree.select.\(worktree.id.raw.uuidString)",
            title: "Switch to Worktree: \(worktree.name)",
            subtitle: project.name,
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
        id: "app.open-settings",
        title: "Open Settings",
        icon: "gearshape",
        shortcut: .command(","),
        commandID: .openSettings,
        kind: .openSettings
      ),
      CommandPaletteItem(
        id: "app.check-for-updates",
        title: "Check for Updates…",
        icon: "arrow.down.circle",
        commandID: .checkForUpdates,
        kind: .checkForUpdates
      ),
      CommandPaletteItem(
        id: "app.quit",
        title: "Quit TouchCode",
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

  private static func worktreeItems(worktreeName: String) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "git.toggle-viewer",
        title: "Toggle Git Viewer",
        subtitle: worktreeName,
        icon: "doc.text.magnifyingglass",
        shortcut: .command("G", shift: true),
        commandID: .toggleDiffInspector,
        kind: .toggleDiffInspector
      ),
      CommandPaletteItem(
        id: "editor.reveal-in-finder",
        title: "Reveal in Finder",
        subtitle: worktreeName,
        icon: "folder",
        commandID: .revealCurrentWorktreeInFinder,
        kind: .revealCurrentWorktreeInFinder
      ),
      CommandPaletteItem(
        id: "worktree.refresh",
        title: "Refresh Worktree",
        subtitle: worktreeName,
        icon: "arrow.clockwise",
        kind: .refreshCurrentWorktree
      ),
      CommandPaletteItem(
        id: "worktree.close",
        title: "Delete Worktree",
        subtitle: worktreeName,
        icon: "xmark.square",
        commandID: .deleteCurrentWorktree,
        hiddenWhenQueryEmpty: true,
        kind: .closeCurrentWorktree
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
        icon: "plus.rectangle.on.rectangle",
        kind: .paneAction(.newTab)
      ),
      CommandPaletteItem(
        id: "pane.equalize",
        title: "Equalize Splits",
        icon: "rectangle.split.3x1",
        kind: .paneAction(.equalizeSplits)
      ),
      CommandPaletteItem(
        id: "pane.close-tab",
        title: "Close Tab",
        icon: "xmark.circle",
        hiddenWhenQueryEmpty: true,
        kind: .paneAction(.closeTab(mode: .this))
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
        icon: "rectangle.split.2x1",
        kind: .paneAction(.newSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "pane.split.down",
        title: "Split Down",
        icon: "rectangle.split.1x2",
        kind: .paneAction(.newSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "pane.focus.left",
        title: "Focus Pane Left",
        icon: "arrow.left",
        kind: .paneAction(.gotoSplit(direction: .left))
      ),
      CommandPaletteItem(
        id: "pane.focus.right",
        title: "Focus Pane Right",
        icon: "arrow.right",
        kind: .paneAction(.gotoSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "pane.focus.up",
        title: "Focus Pane Up",
        icon: "arrow.up",
        kind: .paneAction(.gotoSplit(direction: .up))
      ),
      CommandPaletteItem(
        id: "pane.focus.down",
        title: "Focus Pane Down",
        icon: "arrow.down",
        kind: .paneAction(.gotoSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "pane.toggle-zoom",
        title: "Toggle Split Zoom",
        icon: "plus.magnifyingglass",
        kind: .paneAction(.toggleSplitZoom)
      ),
    ]
  }

  private static func windowItems(focusedPaneID: PaneID) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "window.new",
        title: "New Window",
        icon: "macwindow.badge.plus",
        kind: .windowAction(.new(from: focusedPaneID))
      ),
      CommandPaletteItem(
        id: "window.close",
        title: "Close Window",
        icon: "xmark",
        hiddenWhenQueryEmpty: true,
        kind: .windowAction(.close(from: focusedPaneID))
      ),
      CommandPaletteItem(
        id: "window.toggle-fullscreen",
        title: "Toggle Fullscreen",
        icon: "arrow.up.left.and.arrow.down.right",
        kind: .windowAction(.toggleFullscreen(from: focusedPaneID))
      ),
      CommandPaletteItem(
        id: "window.toggle-tab-overview",
        title: "Show Tab Overview",
        icon: "square.grid.2x2",
        kind: .windowAction(.toggleTabOverview(from: focusedPaneID))
      ),
    ]
  }
}
