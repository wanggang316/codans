import CodansCore
import Foundation
import Testing

@testable import Codans

/// The HUD resolves its decisions from one catalog walk, so these cover what
/// the view cannot re-derive: whether the pane is still known, which agent it
/// carries, whether hand off is offered there, and whether its notifications
/// are muted.
@MainActor
struct PaneHUDModelTests {
  private static func catalog(
    remoteHost: RemoteHost? = nil,
    agentKind: AgentKind? = nil,
    commandQueue: [QueuedCommand] = [],
    labels: Set<String> = [],
    paneID: PaneID
  ) -> Catalog {
    let pane = Pane(
      id: paneID,
      workingDirectory: "/Users/tester/dev/app",
      labels: labels,
      agentKind: agentKind,
      commandQueue: commandQueue
    )
    let tab = Tab(splitTree: SplitTree(leaf: paneID), panes: [pane])
    let worktree = Worktree(
      name: "app",
      path: "/Users/tester/dev/app",
      branch: "main",
      tabs: [tab]
    )
    let project = Project(
      name: "app",
      rootPath: "/Users/tester/dev/app",
      remoteHost: remoteHost,
      worktrees: [worktree]
    )
    return Catalog(projects: [project])
  }

  @Test
  func offersHandOffForAPaneWithAPersistedAgent() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(agentKind: .claudeCode, paneID: paneID),
      agent: nil
    )
    #expect(model?.agent == .claudeCode)
    #expect(model?.canHandOff == true)
  }

  @Test
  func countsThePanesQueuedCommands() {
    let paneID = PaneID()
    let queue = [
      QueuedCommand(text: "make test", timing: .afterCurrentTask),
      QueuedCommand(text: "git status", timing: .scheduled(at: .distantFuture, repeatEvery: nil)),
    ]
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(commandQueue: queue, paneID: paneID),
      agent: nil
    )
    #expect(model?.queuedCommandCount == 2)
  }

  @Test
  func reportsAnEmptyQueueAsZero() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(paneID: paneID),
      agent: nil
    )
    #expect(model?.queuedCommandCount == 0)
  }

  /// The Mute row's checkmark: absent on a freshly-spawned pane, which
  /// carries no labels at all.
  @Test
  func reportsAPaneWithoutTheMuteLabelAsUnmuted() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(paneID: paneID),
      agent: nil
    )
    #expect(model?.isMuted == false)
  }

  /// A mute flipped anywhere — this menu, the right-click menu, a restored
  /// catalog — is the same label, so the HUD reads it back off the pane.
  @Test
  func reportsAPaneCarryingTheMuteLabelAsMuted() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(labels: [InboxLabels.muted], paneID: paneID),
      agent: nil
    )
    #expect(model?.isMuted == true)
  }

  @Test
  func returnsNilForAPaneThatLeftTheCatalog() {
    let model = PaneHUDModel.resolve(
      paneID: PaneID(),
      in: Self.catalog(paneID: PaneID()),
      agent: nil
    )
    #expect(model == nil)
  }

  @Test
  func liveAgentStateWinsOverThePersistedPaneField() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(agentKind: nil, paneID: paneID),
      agent: .codex
    )
    #expect(model?.agent == .codex)
    #expect(model?.canHandOff == true)
  }

  @Test
  func handOffIsBlockedWithoutAnAgent() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(agentKind: nil, paneID: paneID),
      agent: nil
    )
    #expect(model?.canHandOff == false)
    #expect(model?.handOffBlockedReason?.contains("No agent") == true)
  }

  @Test
  func handOffIsBlockedOnServerProjects() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(
        remoteHost: RemoteHost(alias: "mini.local", username: "tester"),
        agentKind: .claudeCode,
        paneID: paneID
      ),
      agent: .claudeCode
    )
    #expect(model?.canHandOff == false)
    #expect(model?.handOffBlockedReason?.contains("Server") == true)
  }
}
