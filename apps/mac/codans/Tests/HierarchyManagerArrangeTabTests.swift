import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct HierarchyManagerArrangeTabTests {
  let fakeRuntime = FakeHierarchyRuntime()
  let fileURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
  let store: CatalogStore
  let manager: HierarchyManager

  init() {
    store = CatalogStore(fileURL: fileURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  private func makeTab(paneCount: Int) async throws -> (ProjectID, WorktreeID, TabID, [PaneID]) {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(in: projectID, name: "main", path: "/repo", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    var paneIDs = [
      try await manager.openPane(
        in: tabID, in: worktreeID, in: projectID, workingDirectory: "/tmp", initialCommand: nil)
    ]
    for _ in 1..<paneCount {
      paneIDs.append(
        try await manager.splitPane(
          paneIDs[paneIDs.count - 1], direction: .down, in: tabID, in: worktreeID, in: projectID,
          workingDirectory: "/tmp", initialCommand: nil))
    }
    return (projectID, worktreeID, tabID, paneIDs)
  }

  private var tab: Tab { manager.catalog.projects[0].worktrees[0].tabs[0] }

  @Test
  func arrangeAppliesThePresetClearsZoomAndKeepsEverySurface() async throws {
    let (projectID, worktreeID, tabID, paneIDs) = try await makeTab(paneCount: 3)
    try manager.focusPane(paneIDs[0], in: tabID, in: worktreeID, in: projectID)
    fakeRuntime.reset()

    try manager.arrangeTab(tabID, in: worktreeID, in: projectID, preset: .mainLeft, focus: paneIDs[2])

    #expect(tab.splitTree.matchingPreset() == .mainLeft)
    #expect(tab.splitTree.leaves() == [paneIDs[2], paneIDs[0], paneIDs[1]])
    #expect(tab.splitTree.zoomed == nil)
    #expect(tab.panes.map(\.id) == paneIDs)
    #expect(fakeRuntime.closeSurfaceCalls.isEmpty)
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
    try tab.validateInvariants()
  }

  @Test
  func arrangedLayoutIsSavedAndLoadsBack() async throws {
    let (projectID, worktreeID, tabID, _) = try await makeTab(paneCount: 4)

    try manager.arrangeTab(tabID, in: worktreeID, in: projectID, preset: .grid, focus: nil)
    store.flushPending()

    let reloaded = try CatalogStore(fileURL: fileURL).load()
    let reloadedTab = try #require(reloaded.projects.first?.worktrees.first?.tabs.first)
    #expect(reloadedTab.splitTree == tab.splitTree)
    #expect(reloadedTab.splitTree.matchingPreset() == .grid)
  }

  @Test
  func arrangeWithAnUnavailablePresetThrowsAndKeepsTheTree() async throws {
    let (projectID, worktreeID, tabID, paneIDs) = try await makeTab(paneCount: 2)
    let before = tab.splitTree

    #expect(throws: SplitTree<PaneID>.SplitError.presetUnavailable) {
      try manager.arrangeTab(tabID, in: worktreeID, in: projectID, preset: .grid, focus: paneIDs[0])
    }
    #expect(tab.splitTree == before)
  }

  @Test
  func arrangeAnUnknownTabThrows() async throws {
    let (projectID, worktreeID, _, _) = try await makeTab(paneCount: 2)
    #expect(throws: HierarchyError.self) {
      try manager.arrangeTab(TabID(), in: worktreeID, in: projectID, preset: .columns, focus: nil)
    }
  }
}
