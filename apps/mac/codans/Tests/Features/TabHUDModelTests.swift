import CodansCore
import Foundation
import Testing

@testable import Codans

/// The HUD resolves its decisions from one catalog walk, so these cover what
/// the view cannot re-derive: whether the pane is still known, which agent it
/// carries, and whether hand off is offered there.
@MainActor
struct TabHUDModelTests {
  private static func catalog(
    remoteHost: RemoteHost? = nil,
    agentKind: AgentKind? = nil,
    commandQueue: [QueuedCommand] = [],
    contentID: ContentID
  ) -> Catalog {
    let tab = Tab(
      content: .terminal(
        id: contentID,
        workingDirectory: "/Users/tester/dev/app",
        agentKind: agentKind,
        commandQueue: commandQueue
      ))
    let pane = Pane(tabs: [tab])
    let worktree = Worktree(
      name: "app",
      path: "/Users/tester/dev/app",
      branch: "main",
      splitTree: SplitTree(leaf: pane.id),
      panes: [pane],
      focusedPaneID: pane.id
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
    let contentID = ContentID()
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(agentKind: .claudeCode, contentID: contentID),
      agent: nil
    )
    #expect(model?.agent == .claudeCode)
    #expect(model?.canHandOff == true)
  }

  @Test
  func countsThePanesQueuedCommands() {
    let contentID = ContentID()
    let queue = [
      QueuedCommand(text: "make test", timing: .afterCurrentTask),
      QueuedCommand(text: "git status", timing: .scheduled(at: .distantFuture, repeatEvery: nil)),
    ]
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(commandQueue: queue, contentID: contentID),
      agent: nil
    )
    #expect(model?.queuedCommandCount == 2)
  }

  @Test
  func reportsAnEmptyQueueAsZero() {
    let contentID = ContentID()
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(contentID: contentID),
      agent: nil
    )
    #expect(model?.queuedCommandCount == 0)
  }

  @Test
  func returnsNilForAPaneThatLeftTheCatalog() {
    let model = TabHUDModel.resolve(
      contentID: ContentID(),
      in: Self.catalog(contentID: ContentID()),
      agent: nil
    )
    #expect(model == nil)
  }

  @Test
  func liveAgentStateWinsOverThePersistedPaneField() {
    let contentID = ContentID()
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(agentKind: nil, contentID: contentID),
      agent: .codex
    )
    #expect(model?.agent == .codex)
    #expect(model?.canHandOff == true)
  }

  @Test
  func handOffIsBlockedWithoutAnAgent() {
    let contentID = ContentID()
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(agentKind: nil, contentID: contentID),
      agent: nil
    )
    #expect(model?.canHandOff == false)
    #expect(model?.handOffBlockedReason?.contains("No agent") == true)
  }

  @Test
  func handOffIsBlockedOnServerProjects() {
    let contentID = ContentID()
    let model = TabHUDModel.resolve(
      contentID: contentID,
      in: Self.catalog(
        remoteHost: RemoteHost(alias: "mini.local", username: "tester"),
        agentKind: .claudeCode,
        contentID: contentID
      ),
      agent: .claudeCode
    )
    #expect(model?.canHandOff == false)
    #expect(model?.handOffBlockedReason?.contains("Server") == true)
  }
}
