import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Coverage for `HierarchyClient.stopScript` — the Run/Stop toggle's teardown.
///
/// Stop interrupts the run Content's child and then closes its Tab. When
/// that Tab was alone in its Pane the Pane goes with it and focus moves to
/// the neighbour, so Stop re-homes input on the survivor the same way the
/// ⌘W / pane-action close paths do.
@MainActor
struct HierarchyClientStopScriptTests {
  @Test
  func stopMovesFocusToTheSurvivingPane() throws {
    let fixture = Self.makeSplitFixture()

    fixture.client.stopScript(fixture.scriptID, fixture.projectID, fixture.worktreeID)

    #expect(fixture.interrupted == [fixture.runContentID])
    #expect(fixture.manager.catalog.content(fixture.runContentID) == nil)
    #expect(fixture.manager.catalog.content(fixture.agentContentID) != nil)
    #expect(fixture.runtime.focusSurfaceViewCalls.last == fixture.agentContentID)
  }

  /// The run Tab alone in the Worktree retires its Pane; there is no
  /// survivor to focus, so no focus request is made.
  @Test
  func stopClosesTheTabWhenTheRunTabIsAlone() throws {
    let fixture = Self.makeSingleTabFixture()

    fixture.client.stopScript(fixture.scriptID, fixture.projectID, fixture.worktreeID)

    #expect(fixture.interrupted == [fixture.runContentID])
    #expect(fixture.manager.catalog.projects[0].worktrees[0].allTabs.isEmpty)
    #expect(fixture.runtime.focusSurfaceViewCalls.isEmpty)
  }

  // MARK: - Fixtures

  private final class InterruptRecorder: @unchecked Sendable {
    var contentIDs: [ContentID] = []
  }

  private struct Fixture {
    let client: HierarchyClient
    let manager: HierarchyManager
    let runtime: FakeHierarchyRuntime
    let scriptID: UUID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let agentContentID: ContentID
    let runContentID: ContentID
    private let recorder: InterruptRecorder

    init(
      client: HierarchyClient,
      manager: HierarchyManager,
      runtime: FakeHierarchyRuntime,
      scriptID: UUID,
      projectID: ProjectID,
      worktreeID: WorktreeID,
      agentContentID: ContentID,
      runContentID: ContentID,
      recorder: InterruptRecorder
    ) {
      self.client = client
      self.manager = manager
      self.runtime = runtime
      self.scriptID = scriptID
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.agentContentID = agentContentID
      self.runContentID = runContentID
      self.recorder = recorder
    }

    var interrupted: [ContentID] { recorder.contentIDs }
  }

  /// Agent Tab on the left, run Tab split off to the right — the layout the
  /// Run/Stop toggle produces with a `.split` command.
  private static func makeSplitFixture() -> Fixture {
    let agentTab = Tab(content: .terminal(workingDirectory: "/repo"))
    let scriptID = UUID()
    let runTab = Tab(content: .terminal(workingDirectory: "/repo", runScriptID: scriptID))
    let agentPane = Pane(tabs: [agentTab])
    let runPane = Pane(tabs: [runTab])
    let worktree = Worktree(
      name: "main", path: "/repo",
      splitTree: SplitTree(
        root: .split(
          SplitTree<PaneID>.Split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(agentPane.id),
            right: .leaf(runPane.id)
          ))
      ),
      panes: [agentPane, runPane],
      focusedPaneID: runPane.id
    )
    return makeFixture(
      worktree: worktree, scriptID: scriptID, agentContentID: agentTab.contentID, runContentID: runTab.contentID
    )
  }

  private static func makeSingleTabFixture() -> Fixture {
    let scriptID = UUID()
    let runTab = Tab(content: .terminal(workingDirectory: "/repo", runScriptID: scriptID))
    let runPane = Pane(tabs: [runTab])
    let worktree = Worktree(
      name: "main", path: "/repo", splitTree: SplitTree(leaf: runPane.id), panes: [runPane],
      focusedPaneID: runPane.id
    )
    return makeFixture(
      worktree: worktree, scriptID: scriptID, agentContentID: runTab.contentID, runContentID: runTab.contentID
    )
  }

  private static func makeFixture(
    worktree: Worktree,
    scriptID: UUID,
    agentContentID: ContentID,
    runContentID: ContentID
  ) -> Fixture {
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
    terminalClient.interrupt = { contentID in recorder.contentIDs.append(contentID) }

    return Fixture(
      client: HierarchyClient.live(manager: manager, terminalClient: terminalClient),
      manager: manager,
      runtime: runtime,
      scriptID: scriptID,
      projectID: project.id,
      worktreeID: worktree.id,
      agentContentID: agentContentID,
      runContentID: runContentID,
      recorder: recorder
    )
  }
}
