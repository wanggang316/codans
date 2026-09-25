import Testing

@testable import CodansIPC

/// Pins the remote exposure of every IPC method. A method added to
/// `IPC.Method` fails `everyMethodHasAFixtureEntry` until it is listed here,
/// so a change to what a phone may call always shows up in review.
struct RemoteTierTests {
  private static let fixture: [IPC.Method: IPC.RemoteTier] = [
    .systemHello: .readOnly,
    .systemPing: .readOnly,
    .systemVersion: .readOnly,
    .systemStatus: .readOnly,
    .systemQuit: .localOnly,

    .editorDescribe: .localOnly,
    .editorOpen: .localOnly,
    .editorSetGlobalDefault: .localOnly,
    .editorSetProjectDefault: .localOnly,

    .hierarchyListProjects: .readOnly,
    .hierarchyListWorktrees: .readOnly,
    .hierarchyListTabs: .readOnly,
    .hierarchyListPanes: .readOnly,
    .hierarchyListTags: .readOnly,
    .hierarchyDescribeProject: .readOnly,
    .hierarchyDescribeWorktree: .readOnly,
    .hierarchyDescribeTab: .readOnly,
    .hierarchyDescribePane: .readOnly,
    .hierarchyResolveAlias: .readOnly,
    .hierarchyResolvePaneLabel: .readOnly,
    .hierarchyResolveWorktreeGlob: .readOnly,
    .hierarchyActivateWorktree: .interactive,
    .hierarchyActivateTab: .interactive,
    .hierarchyFocusPane: .interactive,
    .hierarchyCreateTab: .interactive,
    .hierarchyOpenPane: .interactive,
    .hierarchySplitPane: .interactive,
    .hierarchyZoomPane: .interactive,
    .hierarchyUnzoomPane: .interactive,
    .hierarchyRemoveProject: .localOnly,
    .hierarchyRemoveWorktree: .localOnly,
    .hierarchyPruneWorktrees: .localOnly,
    .hierarchyAddProject: .localOnly,
    .hierarchyRenameProject: .localOnly,
    .hierarchySetProjectEditor: .localOnly,
    .hierarchyCreateWorktree: .interactive,
    .hierarchyRenameWorktree: .localOnly,
    .hierarchyCloseTab: .localOnly,
    .hierarchyRenameTab: .localOnly,
    .hierarchyClosePane: .localOnly,
    .hierarchyResizePane: .localOnly,
    .hierarchySetPaneLabels: .localOnly,
    .hierarchyCreateTag: .localOnly,
    .hierarchyRenameTag: .localOnly,
    .hierarchyRecolorTag: .localOnly,
    .hierarchyRemoveTag: .localOnly,
    .hierarchySetProjectTags: .localOnly,
    .hierarchySetActiveTagFilter: .localOnly,

    .paneRead: .readOnly,
    .paneInfo: .readOnly,
    .paneClose: .localOnly,

    .eventsSubscribe: .readOnly,

    .terminalReadText: .readOnly,
    .terminalSendInput: .interactive,
    .terminalSendKey: .interactive,
    .terminalRetryPane: .interactive,
    .terminalBroadcastInput: .localOnly,
    .terminalSendRawBytes: .localOnly,
    .terminalResetPane: .localOnly,

    .projectListScripts: .readOnly,
    .projectAddScript: .localOnly,
    .projectUpdateScript: .localOnly,
    .projectRemoveScript: .localOnly,

    .agentListStates: .readOnly,
    .agentListProfiles: .readOnly,
    .agentLaunch: .interactive,
    .agentWait: .localOnly,

    .handoffSave: .localOnly,
    .handoffTo: .localOnly,

    .workspaceDescribe: .readOnly,
    .workspaceCreate: .localOnly,
    .workspaceAdd: .localOnly,
    .workspaceDrop: .localOnly,
    .workspaceRemove: .localOnly,
  ]

  /// Security position, not backlog: these must stay unreachable remotely
  /// at every permission level.
  private static let neverRemote: Set<IPC.Method> = [
    .systemQuit,
    .editorDescribe, .editorOpen, .editorSetGlobalDefault, .editorSetProjectDefault,
    .hierarchyRemoveProject, .hierarchyRemoveWorktree, .hierarchyPruneWorktrees,
    .projectAddScript, .projectUpdateScript, .projectRemoveScript,
    .workspaceRemove,
    .terminalBroadcastInput, .terminalSendRawBytes,
  ]

  @Test
  func everyMethodHasAFixtureEntry() {
    let missing = IPC.Method.allCases.filter { Self.fixture[$0] == nil }
    #expect(missing.isEmpty, "add a remote tier fixture entry for: \(missing.map(\.rawValue))")
    #expect(Self.fixture.count == IPC.Method.allCases.count)
  }

  @Test(arguments: IPC.Method.allCases)
  func tierMatchesFixture(_ method: IPC.Method) {
    #expect(method.remoteTier == Self.fixture[method], "\(method.rawValue)")
  }

  @Test
  func neverRemoteMethodsAreLocalOnly() {
    for method in Self.neverRemote {
      #expect(method.remoteTier == .localOnly, "\(method.rawValue)")
      for permission in IPC.RemotePermission.allCases {
        #expect(!permission.allows(method), "\(permission) must not reach \(method.rawValue)")
      }
    }
  }

  @Test
  func permissionMatrix() {
    #expect(IPC.RemotePermission.readOnly.allows(.readOnly))
    #expect(!IPC.RemotePermission.readOnly.allows(.interactive))
    #expect(!IPC.RemotePermission.readOnly.allows(.localOnly))
    #expect(IPC.RemotePermission.interactive.allows(.readOnly))
    #expect(IPC.RemotePermission.interactive.allows(.interactive))
    #expect(!IPC.RemotePermission.interactive.allows(.localOnly))
  }

  @Test
  func readOnlyDeviceCannotType() {
    #expect(!IPC.RemotePermission.readOnly.allows(.terminalSendInput))
    #expect(IPC.RemotePermission.interactive.allows(.terminalSendInput))
    #expect(IPC.RemotePermission.readOnly.allows(.eventsSubscribe))
  }
}
