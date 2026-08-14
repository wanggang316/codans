import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Coverage for `HierarchyClient.stopScript` — the Run/Stop toggle's teardown.
///
/// Stop interrupts the run pane's child and then closes it: the whole Tab when
/// the run pane is the Tab's only pane, otherwise just that pane. The pane
/// close drops the Tab's last-focused entry (run panes spawn with
/// `focus: true`, so the run pane usually owns it), so Stop has to re-home
/// input on the survivor the same way the ⌘W / pane-action close paths do.
@MainActor
struct HierarchyClientStopScriptTests {
  @Test
  func stopMovesFocusToTheSurvivingPane() throws {
    let fixture = Self.makeSplitFixture()

    fixture.client.stopScript(fixture.scriptID, fixture.projectID, fixture.worktreeID)

    #expect(fixture.interrupted == [fixture.runPaneID])
    #expect(fixture.manager.catalog.pane(fixture.runPaneID) == nil)
    #expect(fixture.manager.catalog.pane(fixture.agentPaneID) != nil)
    #expect(fixture.runtime.focusSurfaceViewCalls.last == fixture.agentPaneID)
  }

  /// The run pane alone in its Tab retires the Tab; there is no survivor to
  /// focus, so no focus request is made.
  @Test
  func stopClosesTheTabWhenTheRunPaneIsAlone() throws {
    let fixture = Self.makeSinglePaneFixture()

    fixture.client.stopScript(fixture.scriptID, fixture.projectID, fixture.worktreeID)

    #expect(fixture.interrupted == [fixture.runPaneID])
    #expect(fixture.manager.catalog.projects[0].worktrees[0].tabs.isEmpty)
    #expect(fixture.runtime.focusSurfaceViewCalls.isEmpty)
  }

  // MARK: - Fixtures

  private final class InterruptRecorder: @unchecked Sendable {
    var paneIDs: [PaneID] = []
  }

  private struct Fixture {
    let client: HierarchyClient
    let manager: HierarchyManager
    let runtime: FakeHierarchyRuntime
    let scriptID: UUID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let agentPaneID: PaneID
    let runPaneID: PaneID
    private let recorder: InterruptRecorder

    init(
      client: HierarchyClient,
      manager: HierarchyManager,
      runtime: FakeHierarchyRuntime,
      scriptID: UUID,
      projectID: ProjectID,
      worktreeID: WorktreeID,
      agentPaneID: PaneID,
      runPaneID: PaneID,
      recorder: InterruptRecorder
    ) {
      self.client = client
      self.manager = manager
      self.runtime = runtime
      self.scriptID = scriptID
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.agentPaneID = agentPaneID
      self.runPaneID = runPaneID
      self.recorder = recorder
    }

    var interrupted: [PaneID] { recorder.paneIDs }
  }

  /// Agent pane on the left, run pane split off to the right — the layout the
  /// Run/Stop toggle produces with a `.split` command.
  private static func makeSplitFixture() -> Fixture {
    let agentPane = Pane(workingDirectory: "/repo")
    let scriptID = UUID()
    let runPane = Pane(workingDirectory: "/repo", runScriptID: scriptID)
    let tab = Tab(
      splitTree: SplitTree(
        root: .split(
          SplitTree<PaneID>.Split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(agentPane.id),
            right: .leaf(runPane.id)
          ))
      ),
      panes: [agentPane, runPane]
    )
    return makeFixture(
      tab: tab, scriptID: scriptID, agentPaneID: agentPane.id, runPaneID: runPane.id
    )
  }

  private static func makeSinglePaneFixture() -> Fixture {
    let scriptID = UUID()
    let runPane = Pane(workingDirectory: "/repo", runScriptID: scriptID)
    let tab = Tab(splitTree: SplitTree(leaf: runPane.id), panes: [runPane])
    return makeFixture(
      tab: tab, scriptID: scriptID, agentPaneID: runPane.id, runPaneID: runPane.id
    )
  }

  private static func makeFixture(
    tab: Tab,
    scriptID: UUID,
    agentPaneID: PaneID,
    runPaneID: PaneID
  ) -> Fixture {
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-stop-script-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(fileURL: dir.appendingPathComponent("catalog.json")),
      runtime: runtime
    )

    let recorder = InterruptRecorder()
    var terminalClient = TerminalClient.testValue
    terminalClient.interrupt = { paneID in recorder.paneIDs.append(paneID) }

    return Fixture(
      client: HierarchyClient.live(manager: manager, terminalClient: terminalClient),
      manager: manager,
      runtime: runtime,
      scriptID: scriptID,
      projectID: project.id,
      worktreeID: worktree.id,
      agentPaneID: agentPaneID,
      runPaneID: runPaneID,
      recorder: recorder
    )
  }
}
