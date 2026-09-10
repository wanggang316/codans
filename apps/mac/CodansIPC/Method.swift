import Foundation

extension IPC {
  /// Every RPC method. Raw values are the on-wire method strings — lowercase
  /// dotted identifiers. Both client and server switch on this enum, never on
  /// the raw string.
  ///
  /// `skill.*` methods are intentionally absent — the skill surface is deferred.
  public enum Method: String, Codable, Hashable, Sendable, CaseIterable {
    // system
    case systemHello = "system.hello"
    case systemPing = "system.ping"
    case systemVersion = "system.version"
    case systemStatus = "system.status"
    case systemQuit = "system.quit"

    // editor — `editor.*` IPC surface. Handlers live in `EditorHandlers`;
    // `MethodRouter` dispatches each case. `setGlobalDefault` and
    // `setProjectDefault` are distinct verbs (global vs per-Project override).
    case editorDescribe = "editor.describe"
    case editorOpen = "editor.open"
    case editorSetGlobalDefault = "editor.setGlobalDefault"
    case editorSetProjectDefault = "editor.setProjectDefault"

    // project — per-Project settings reads/writes that live in
    // `settings.json` (owned by `SettingsStore`), distinct from the
    // catalog-backed `hierarchy.*` surface. Handlers live in
    // `ProjectHandlers`. `listScripts` reads `ProjectSettings.scripts`.
    case projectListScripts = "project.listScripts"
    case projectAddScript = "project.addScript"
    case projectUpdateScript = "project.updateScript"
    case projectRemoveScript = "project.removeScript"

    // agent — launch presets from `Settings.agents`. Handlers live in
    // `AgentHandlers`. `launch` renders the profile through the same
    // pipeline the toolbar Agents menu uses, optionally seeded with a
    // kickoff prompt.
    case agentListProfiles = "agent.listProfiles"
    case agentLaunch = "agent.launch"
    // `listStates` reads the Agents View's per-pane runtime state; `wait`
    // blocks server-side until a pane's agent reaches a condition or the
    // request's deadline passes.
    case agentListStates = "agent.listStates"
    case agentWait = "agent.wait"

    // handoff — agent-to-agent transition over `.codans/handoff/`. The
    // source pane is resolved by the CLI (`current` → caller pane);
    // handlers live in `HandoffHandlers`.
    case handoffSave = "handoff.save"
    case handoffTo = "handoff.to"

    // workspace — multi-repository workspaces. `create` and `add`
    // materialize checkouts on disk before touching the catalog; handlers
    // live in `WorkspaceHandlers`.
    case workspaceCreate = "workspace.create"
    case workspaceAdd = "workspace.add"
    case workspaceDescribe = "workspace.describe"

    // hierarchy — reads
    case hierarchyListProjects = "hierarchy.listProjects"
    case hierarchyListWorktrees = "hierarchy.listWorktrees"
    case hierarchyListTabs = "hierarchy.listTabs"
    case hierarchyListPanes = "hierarchy.listPanes"
    case hierarchyListTags = "hierarchy.listTags"
    case hierarchyDescribeProject = "hierarchy.describeProject"
    case hierarchyDescribeWorktree = "hierarchy.describeWorktree"
    case hierarchyDescribeTab = "hierarchy.describeTab"
    case hierarchyDescribePane = "hierarchy.describePane"
    case hierarchyResolveAlias = "hierarchy.resolveAlias"
    case hierarchyResolvePaneLabel = "hierarchy.resolvePaneLabel"
    case hierarchyResolveWorktreeGlob = "hierarchy.resolveWorktreeGlob"

    // hierarchy — mutations
    case hierarchyAddProject = "hierarchy.addProject"
    case hierarchyRemoveProject = "hierarchy.removeProject"
    case hierarchyRenameProject = "hierarchy.renameProject"
    case hierarchySetProjectEditor = "hierarchy.setProjectEditor"
    case hierarchyCreateWorktree = "hierarchy.createWorktree"
    case hierarchyRemoveWorktree = "hierarchy.removeWorktree"
    case hierarchyActivateWorktree = "hierarchy.activateWorktree"
    case hierarchyRenameWorktree = "hierarchy.renameWorktree"
    case hierarchyPruneWorktrees = "hierarchy.pruneWorktrees"
    case hierarchyCreateTab = "hierarchy.createTab"
    case hierarchyCloseTab = "hierarchy.closeTab"
    case hierarchyActivateTab = "hierarchy.activateTab"
    case hierarchyRenameTab = "hierarchy.renameTab"
    case hierarchyOpenPane = "hierarchy.openPane"
    case hierarchySplitPane = "hierarchy.splitPane"
    case hierarchyClosePane = "hierarchy.closePane"
    case hierarchyFocusPane = "hierarchy.focusPane"
    case hierarchyResizePane = "hierarchy.resizePane"
    case hierarchyZoomPane = "hierarchy.zoomPane"
    case hierarchyUnzoomPane = "hierarchy.unzoomPane"
    case hierarchySetPaneLabels = "hierarchy.setPaneLabels"
    case hierarchyCreateTag = "hierarchy.createTag"
    case hierarchyRenameTag = "hierarchy.renameTag"
    case hierarchyRecolorTag = "hierarchy.recolorTag"
    case hierarchyRemoveTag = "hierarchy.removeTag"
    case hierarchySetProjectTags = "hierarchy.setProjectTags"
    case hierarchySetActiveTagFilter = "hierarchy.setActiveTagFilter"

    // pane — explicit-termination verbs that own the zmx daemon
    // lifecycle (kill + sessions.json reap), distinct from the
    // detach-only `hierarchy.closePane` mutation above. `pane.info`
    // and `pane.read` probe the daemon directly so VT-fidelity tests
    // can assert byte-level state (cursor, modes, serialized history)
    // that libghostty's parsed-text surface does not expose.
    case paneClose = "pane.close"
    case paneInfo = "pane.info"
    case paneRead = "pane.read"

    // terminal
    case terminalSendInput = "terminal.sendInput"
    case terminalSendKey = "terminal.sendKey"
    case terminalSendRawBytes = "terminal.sendRawBytes"
    case terminalBroadcastInput = "terminal.broadcastInput"
    case terminalReadText = "terminal.readText"
    case terminalRetryPane = "terminal.retryPane"
    case terminalResetPane = "terminal.resetPane"
  }
}
