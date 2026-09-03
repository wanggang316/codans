import CodansCore
import Foundation
import Testing

@testable import Codans

/// The HUD resolves its whole card from one catalog walk, so these cover the
/// two decisions the view cannot re-derive: which worktree a pane belongs to,
/// and whether hand off is offered there.
@MainActor
struct PaneHUDModelTests {
  private static let home = "/Users/tester"

  private static func catalog(
    remoteHost: RemoteHost? = nil,
    agentKind: AgentKind? = nil,
    branch: String? = "main",
    paneID: PaneID
  ) -> Catalog {
    let pane = Pane(
      id: paneID,
      workingDirectory: "\(home)/dev/app",
      agentKind: agentKind
    )
    let tab = Tab(splitTree: SplitTree(leaf: paneID), panes: [pane])
    let worktree = Worktree(
      name: "app",
      path: "\(home)/dev/app",
      branch: branch,
      tabs: [tab]
    )
    let project = Project(
      name: "app",
      rootPath: "\(home)/dev/app",
      remoteHost: remoteHost,
      worktrees: [worktree]
    )
    return Catalog(projects: [project])
  }

  @Test
  func resolvesTheWorktreeThePaneRunsIn() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(agentKind: .claudeCode, paneID: paneID),
      agent: nil,
      diff: { _ in LocalDiffStats(additions: 3, deletions: 1) },
      homeDirectory: Self.home
    )
    #expect(model?.displayPath == "~/dev/app")
    #expect(model?.branch == "main")
    #expect(model?.diff == LocalDiffStats(additions: 3, deletions: 1))
    #expect(model?.canHandOff == true)
  }

  @Test
  func returnsNilForAPaneThatLeftTheCatalog() {
    let model = PaneHUDModel.resolve(
      paneID: PaneID(),
      in: Self.catalog(paneID: PaneID()),
      agent: nil,
      diff: { _ in nil },
      homeDirectory: Self.home
    )
    #expect(model == nil)
  }

  @Test
  func liveAgentStateWinsOverThePersistedPaneField() {
    let paneID = PaneID()
    let model = PaneHUDModel.resolve(
      paneID: paneID,
      in: Self.catalog(agentKind: nil, paneID: paneID),
      agent: .codex,
      diff: { _ in nil },
      homeDirectory: Self.home
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
      agent: nil,
      diff: { _ in nil },
      homeDirectory: Self.home
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
      agent: .claudeCode,
      diff: { _ in nil },
      homeDirectory: Self.home
    )
    #expect(model?.canHandOff == false)
    #expect(model?.handOffBlockedReason?.contains("Server") == true)
  }

  @Test
  func pathsOutsideHomeStayAbsolute() {
    #expect(PaneHUDModel.displayPath("/opt/src", home: Self.home) == "/opt/src")
    #expect(PaneHUDModel.displayPath(Self.home, home: Self.home) == "~")
    #expect(PaneHUDModel.displayPath("\(Self.home)/a", home: Self.home) == "~/a")
    // A sibling directory whose name starts with the home path must not be
    // mistaken for a child of it.
    #expect(PaneHUDModel.displayPath("\(Self.home)-old/a", home: Self.home) == "\(Self.home)-old/a")
  }
}
