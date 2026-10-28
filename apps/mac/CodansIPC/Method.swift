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

    // workspace — multi-repository workspaces. `create` / `add` / `drop`
    // edit the source projects; `createGroup` / `deleteGroup` create and
    // delete the checkouts of a named group. Handlers live in
    // `WorkspaceHandlers` and call `WorkspaceClient` only.
    case workspaceCreate = "workspace.create"
    case workspaceAdd = "workspace.add"
    case workspaceDrop = "workspace.drop"
    case workspaceRemove = "workspace.remove"
    case workspaceDescribe = "workspace.describe"
    case workspaceCreateGroup = "workspace.createGroup"
    case workspaceCheckGroupDeletion = "workspace.checkGroupDeletion"
    case workspaceDeleteGroup = "workspace.deleteGroup"

    // workflow — multi-agent runs driven by `<id>.workflow.yaml` files.
    // `list` / `run` / `listRuns` scope by worktree (or the caller's pane);
    // `status` / `deliver` attribute an argument-less call to the caller's
    // pane the way `handoff` does. `validate` never touches IPC — the CLI
    // parses offline. Handlers live in `WorkflowHandlers`.
    case workflowList = "workflow.list"
    case workflowRun = "workflow.run"
    case workflowStatus = "workflow.status"
    case workflowDeliver = "workflow.deliver"
    case workflowResolve = "workflow.resolve"
    case workflowCancel = "workflow.cancel"
    case workflowListRuns = "workflow.listRuns"

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
    // Tab verbs act on one strip slot and its Content; Pane verbs act on
    // the layout. Any id parameter is the level the method names.
    case hierarchyCreateTab = "hierarchy.createTab"
    case hierarchyCloseTab = "hierarchy.closeTab"
    case hierarchyActivateTab = "hierarchy.activateTab"
    case hierarchyRenameTab = "hierarchy.renameTab"
    case hierarchySetTabLabels = "hierarchy.setTabLabels"
    case hierarchySplitPane = "hierarchy.splitPane"
    case hierarchyClosePane = "hierarchy.closePane"
    case hierarchyFocusPane = "hierarchy.focusPane"
    case hierarchyResizePane = "hierarchy.resizePane"
    case hierarchyEqualizePanes = "hierarchy.equalizePanes"
    case hierarchyZoomPane = "hierarchy.zoomPane"
    case hierarchyUnzoomPane = "hierarchy.unzoomPane"
    case hierarchyCreateTag = "hierarchy.createTag"
    case hierarchyRenameTag = "hierarchy.renameTag"
    case hierarchyRecolorTag = "hierarchy.recolorTag"
    case hierarchyRemoveTag = "hierarchy.removeTag"
    case hierarchySetProjectTags = "hierarchy.setProjectTags"
    case hierarchySetActiveTagFilter = "hierarchy.setActiveTagFilter"

    // tab — probes of a Tab's zmx daemon. They reach the daemon directly
    // so VT-fidelity tests can assert byte-level state (cursor, modes,
    // serialized history) that libghostty's parsed-text surface does not
    // expose.
    case tabInfo = "tab.info"
    case tabRead = "tab.read"

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
