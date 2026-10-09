import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// The phase 2 summary fields: split layout, zoom, working directory,
/// liveness and the Mac's active pane.
@MainActor
struct EventProjectionTests {
  private let pane1 = Pane(workingDirectory: "/repo")
  private let pane2 = Pane(workingDirectory: "/repo/sub")
  private let pane3 = Pane(workingDirectory: "/repo")

  private func catalog() throws -> Catalog {
    let tree = try SplitTree(leaf: pane1.id)
      .inserting(pane2.id, at: pane1.id, direction: .right)
      .inserting(pane3.id, at: pane2.id, direction: .down)
    let tab = Tab(splitTree: SplitTree(root: tree.root, zoomed: pane3.id), panes: [pane1, pane2, pane3])
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab])
    return Catalog(projects: [Project(name: "repo", rootPath: "/repo", worktrees: [worktree])])
  }

  private func summary(
    liveDirectory: (PaneID) -> String? = { _ in nil },
    paneIsLive: ((PaneID) -> Bool)? = nil,
    activePaneID: PaneID? = nil
  ) throws -> IPC.HierarchySummary {
    EventProjection.hierarchySummary(
      catalog: try catalog(),
      handles: IPC.TargetHandles(tabs: [:], panes: [:]),
      focusedPane: { _ in nil },
      paneTitle: { _ in nil },
      activePaneID: activePaneID,
      liveDirectory: liveDirectory,
      paneIsLive: paneIsLive)
  }

  @Test
  func tabCarriesItsSplitTreeAndZoomedPane() throws {
    let tab = try #require(try summary().projects.first?.worktrees.first?.tabs.first)
    #expect(
      tab.layout
        == .split(
          direction: .horizontal, ratio: 0.5,
          left: .leaf(paneID: pane1.id.description),
          right: .split(
            direction: .vertical, ratio: 0.5,
            left: .leaf(paneID: pane2.id.description),
            right: .leaf(paneID: pane3.id.description))))
    #expect(tab.layout?.paneIDs == [pane1, pane2, pane3].map(\.id.description))
    #expect(tab.zoomedPaneID == pane3.id.description)
  }

  @Test
  func paneReportsLiveDirectoryAndLiveness() throws {
    let live = pane2.id
    let result = try summary(
      liveDirectory: { $0 == live ? "/tmp/elsewhere" : nil },
      paneIsLive: { $0 == live },
      activePaneID: live)
    let panes = try #require(result.projects.first?.worktrees.first?.tabs.first?.panes)
    #expect(panes.map(\.cwd) == ["/repo", "/tmp/elsewhere", "/repo"])
    #expect(panes.map(\.isLive) == [false, true, false])
    #expect(result.activePaneID == live.description)
  }

  @Test
  func livenessIsOmittedWithoutARuntime() throws {
    let panes = try #require(try summary().projects.first?.worktrees.first?.tabs.first?.panes)
    #expect(panes.allSatisfy { $0.isLive == nil })
  }
}
