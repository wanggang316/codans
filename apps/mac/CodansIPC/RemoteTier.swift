import Foundation

extension IPC {
  /// How far a method may be exposed to a paired remote device (the LAN
  /// gateway). Local callers on the Unix socket are never gated by this.
  public enum RemoteTier: String, Codable, Hashable, Sendable, CaseIterable {
    /// Callable by every paired device.
    case readOnly
    /// Callable only by devices paired with the interactive permission.
    case interactive
    /// Never callable remotely, whatever the device's permission.
    case localOnly
  }

  /// The permission a paired device holds. A device may call a method when
  /// `permission.allows(method.remoteTier)`.
  public enum RemotePermission: String, Codable, Hashable, Sendable, CaseIterable {
    case readOnly
    case interactive

    public func allows(_ tier: RemoteTier) -> Bool {
      switch (self, tier) {
      case (_, .readOnly): return true
      case (.interactive, .interactive): return true
      case (.readOnly, .interactive): return false
      case (_, .localOnly): return false
      }
    }

    public func allows(_ method: Method) -> Bool {
      allows(method.remoteTier)
    }
  }
}

extension IPC.Method {
  /// Remote exposure of this method. Deliberately an exhaustive switch with
  /// no `default`: adding a method does not compile until someone decides
  /// whether a phone may call it. See the iOS companion design doc's
  /// permission tiers for the reasoning behind each group.
  public var remoteTier: IPC.RemoteTier {
    switch self {
    // Reads: state a paired device needs to render the hierarchy and
    // agents, plus the handshake and health probes.
    case .systemHello, .systemPing, .systemVersion, .systemStatus,
      .hierarchyListProjects, .hierarchyListWorktrees, .hierarchyListTabs,
      .hierarchyListPanes, .hierarchyListTags,
      .hierarchyDescribeProject, .hierarchyDescribeWorktree, .hierarchyDescribeTab,
      .hierarchyDescribePane,
      .hierarchyResolveAlias, .hierarchyResolvePaneLabel, .hierarchyResolveWorktreeGlob,
      .agentListStates, .agentListProfiles,
      .paneRead, .paneInfo,
      .terminalReadText,
      .workspaceDescribe,
      .projectListScripts,
      .eventsSubscribe:
      return .readOnly

    // Typing into a pane and navigating: equivalent to shell access, so
    // opt-in per device.
    // Creating a worktree runs git on the Mac but only ever adds: the
    // router further limits a remote caller to a branch name, so it cannot
    // choose where on disk the worktree lands.
    case .terminalSendInput, .terminalSendKey, .terminalRetryPane,
      .agentLaunch, .hierarchyCreateWorktree,
      .hierarchyActivateWorktree, .hierarchyActivateTab, .hierarchyFocusPane,
      .hierarchyCreateTab, .hierarchyOpenPane, .hierarchySplitPane,
      .hierarchyZoomPane, .hierarchyUnzoomPane:
      return .interactive

    // Never remote: destroys data, persists commands that later run as the
    // user, acts outside codans' own window, or widens one keystroke's
    // blast radius beyond the pane on screen.
    case .systemQuit,
      .editorDescribe, .editorOpen, .editorSetGlobalDefault, .editorSetProjectDefault,
      .hierarchyRemoveProject, .hierarchyRemoveWorktree, .hierarchyPruneWorktrees,
      .projectAddScript, .projectUpdateScript, .projectRemoveScript,
      .workspaceRemove,
      .terminalBroadcastInput, .terminalSendRawBytes:
      return .localOnly

    // Not remote in v1; promoting any of these needs a design change.
    // `agent.wait` blocks its connection and the event stream answers the
    // same question.
    case .hierarchyAddProject, .hierarchyRenameProject, .hierarchySetProjectEditor,
      .hierarchyRenameWorktree,
      .hierarchyCloseTab, .hierarchyRenameTab,
      .hierarchyClosePane, .hierarchyResizePane, .hierarchySetPaneLabels,
      .hierarchyCreateTag, .hierarchyRenameTag, .hierarchyRecolorTag, .hierarchyRemoveTag,
      .hierarchySetProjectTags, .hierarchySetActiveTagFilter,
      .paneClose,
      .terminalResetPane,
      .workspaceCreate, .workspaceAdd, .workspaceDrop,
      .handoffSave, .handoffTo,
      .agentWait:
      return .localOnly
    }
  }
}
