import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `codans <kind> show` reaches `hierarchy.describe*`: one entity by id,
/// with containers, handle, selection / focus, and the live directory.
@MainActor
struct HierarchyHandlersDescribeTests {
  @Test
  func describeTabCarriesPaneContentChipAndSessionFields() async throws {
    let fixture = Fixture()
    fixture.runtime.currentWorkingDirectories[fixture.content2] = "/live/dir"
    // Agent bindings are session state: the manager clears persisted ones
    // on load, so bind through its writer like the classifier does.
    fixture.manager.setAgentKind(fixture.content2, kind: .amp)
    try fixture.manager.setTabColor(fixture.tab2.id, color: .blue)

    let outcome = await fixture.handlers.describeTab(try Self.request(fixture.tab2.id.raw))
    let description: IPC.TabDescription = try Self.decodeUnary(outcome)

    #expect(description.id == fixture.tab2.id.description)
    #expect(description.handle == "t2")
    #expect(description.projectID == fixture.project.id.description)
    #expect(description.worktreeID == fixture.worktree.id.description)
    #expect(description.paneID == fixture.pane2.id.description)
    #expect(description.contentID == fixture.content2.description)
    #expect(description.color == .blue)
    #expect(description.isSelected)
    #expect(description.workingDirectory == "/live/dir")
    #expect(description.labels == ["agent", "worker"])
    #expect(description.agent == "amp")
    #expect(!description.isLive)
  }

  /// Any of the three ids describes the Tab: a Content id names its Tab, a
  /// Pane id its selected Tab.
  @Test
  func describeTabAcceptsContentAndPaneIds() async throws {
    let fixture = Fixture()

    for id in [fixture.content2.raw, fixture.pane2.id.raw] {
      let outcome = await fixture.handlers.describeTab(try Self.request(id))
      let description: IPC.TabDescription = try Self.decodeUnary(outcome)
      #expect(description.id == fixture.tab2.id.description)
    }
  }

  @Test
  func describeTabReportsLiveWhenAProbeIsBound() async throws {
    let fixture = Fixture(probeIsBound: true)

    let outcome = await fixture.handlers.describeTab(try Self.request(fixture.tab1.id.raw))
    let description: IPC.TabDescription = try Self.decodeUnary(outcome)

    #expect(description.isLive)
    #expect(description.workingDirectory == "/repo")
  }

  @Test
  func describeTabFallsBackToTheCachedTitle() async throws {
    let fixture = Fixture()

    let outcome = await fixture.handlers.describeTab(try Self.request(fixture.tab1.id.raw))
    let description: IPC.TabDescription = try Self.decodeUnary(outcome)

    #expect(description.handle == "t1")
    #expect(description.title == "zsh — repo")
    #expect(description.name == nil)
  }

  @Test
  func describePaneCarriesHandleStripAndFocus() async throws {
    let fixture = Fixture()
    try fixture.manager.focusPane(fixture.pane2.id)

    let outcome = await fixture.handlers.describePane(try Self.request(fixture.pane2.id.raw))
    let description: IPC.PaneDescription = try Self.decodeUnary(outcome)

    #expect(description.id == fixture.pane2.id.description)
    #expect(description.handle == "p2")
    #expect(description.projectID == fixture.project.id.description)
    #expect(description.worktreeID == fixture.worktree.id.description)
    #expect(description.selectedTabID == fixture.tab2.id.description)
    #expect(description.tabIDs == [fixture.tab2.id.description])
    #expect(description.isFocused)
  }

  /// A Tab or Content id describes the Pane holding it.
  @Test
  func describePaneAcceptsTabAndContentIds() async throws {
    let fixture = Fixture()

    for id in [fixture.tab1.id.raw, fixture.content1.raw] {
      let outcome = await fixture.handlers.describePane(try Self.request(id))
      let description: IPC.PaneDescription = try Self.decodeUnary(outcome)
      #expect(description.id == fixture.pane1.id.description)
      #expect(description.handle == "p1")
      #expect(description.isFocused)
    }
  }

  @Test
  func describeWorktreeAndProjectReportSelectionAndCounts() async throws {
    let fixture = Fixture()

    let worktreeOutcome = await fixture.handlers.describeWorktree(
      try Self.request(fixture.worktree.id.raw))
    let worktree: IPC.WorktreeDescription = try Self.decodeUnary(worktreeOutcome)
    #expect(worktree.projectName == "repo")
    #expect(worktree.branch == "main")
    #expect(worktree.isSelected)
    #expect(worktree.paneCount == 2)
    #expect(worktree.focusedPaneID == fixture.pane1.id.description)

    let projectOutcome = await fixture.handlers.describeProject(
      try Self.request(fixture.project.id.raw))
    let project: IPC.ProjectDescription = try Self.decodeUnary(projectOutcome)
    #expect(project.name == "repo")
    #expect(project.gitRoot == "/repo")
    #expect(project.isSelected)
    #expect(project.worktreeCount == 1)
    #expect(project.archivedWorktreeCount == 1)
    #expect(project.selectedWorktreeID == fixture.worktree.id.description)
  }

  @Test
  func unknownIdsAreNotFoundPerKind() async throws {
    let fixture = Fixture()
    let params = try Self.request(UUID())

    for (outcome, kind) in [
      (await fixture.handlers.describeProject(params), "project"),
      (await fixture.handlers.describeWorktree(params), "worktree"),
      (await fixture.handlers.describeTab(params), "tab"),
      (await fixture.handlers.describePane(params), "pane"),
    ] {
      guard case .failed(.notFound(let gotKind, _)) = outcome else {
        Issue.record("expected .notFound for \(kind), got \(outcome)")
        continue
      }
      #expect(gotKind == kind)
    }
  }

  private static func request(_ id: UUID) throws -> JSONValue {
    try JSONValue.encoded(IPC.DescribeRequest(id: id))
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  /// One project, one live worktree (plus an archived one), two Panes side
  /// by side with one Tab each; the whole chain is selected and the left
  /// Pane is focused.
  @MainActor
  private struct Fixture {
    let runtime = FakeHierarchyRuntime()
    let manager: HierarchyManager
    let handlers: HierarchyHandlers
    let project: Project
    let worktree: Worktree
    let tab1: Tab
    let tab2: Tab
    let pane1: Pane
    let pane2: Pane
    var content1: ContentID { tab1.contentID }
    var content2: ContentID { tab2.contentID }

    init(probeIsBound: Bool = false) {
      let tab1 = Tab(cachedDisplayTitle: "zsh — repo", content: .terminal(workingDirectory: "/repo"))
      let tab2 = Tab(content: .terminal(workingDirectory: "/repo/src", labels: ["worker", "agent"]))
      let pane1 = Pane(tabs: [tab1])
      let pane2 = Pane(tabs: [tab2])
      // swiftlint:disable:next force_try
      let splitTree = try! SplitTree(leaf: pane1.id).inserting(pane2.id, at: pane1.id, direction: .right)
      let worktree = Worktree(
        name: "main", path: "/repo", branch: "main",
        splitTree: splitTree, panes: [pane1, pane2], focusedPaneID: pane1.id)
      let archived = Worktree(name: "old", path: "/repo-old", branch: "old", archived: true)
      let project = Project(
        name: "repo", rootPath: "/repo", gitRoot: "/repo",
        worktrees: [worktree, archived], selectedWorktreeID: worktree.id)
      let manager = HierarchyManager(
        catalog: Catalog(projects: [project], selectedProjectID: project.id),
        store: CatalogStore(
          fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codans-describe-\(UUID().uuidString).json")
        ),
        runtime: runtime
      )
      self.manager = manager
      self.handlers = HierarchyHandlers(
        manager: manager,
        runtimeProbe: { _ in probeIsBound ? ProbeStub() : nil }
      )
      self.project = project
      self.worktree = worktree
      self.tab1 = tab1
      self.tab2 = tab2
      self.pane1 = pane1
      self.pane2 = pane2
    }
  }

  /// Stands in for a bound daemon probe; `describePane` only checks that
  /// one exists. `async` is the protocol's shape, hence the lint marker.
  private final class ProbeStub: PaneRuntimeProbe {
    // swiftlint:disable async_without_await
    func requestInfo() async throws -> ZmxInfoPayload { throw TestError.unexpectedOutcome }
    func readHistory(format: ZmxHistoryFormat) async throws -> Data { Data() }
    // swiftlint:enable async_without_await
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
