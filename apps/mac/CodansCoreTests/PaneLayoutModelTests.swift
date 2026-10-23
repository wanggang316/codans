import Foundation
import Testing

@testable import CodansCore

/// `Worktree` layout invariants: split-tree leaves equal the Pane set, a
/// Pane is never empty, every selection and the focus resolve, Tab and
/// Content ids are unique per Worktree.
struct PaneLayoutModelTests {
  // MARK: - Fixtures

  private func terminalTab(_ directory: String = "/tmp") -> Tab {
    Tab(content: .terminal(workingDirectory: directory))
  }

  /// A Worktree whose panes are laid out left to right in array order.
  private func worktree(_ panes: [Pane]) throws -> Worktree {
    var tree = SplitTree<PaneID>()
    for pane in panes {
      if let anchor = tree.leaves().last {
        tree = try tree.inserting(pane.id, at: anchor, direction: .right)
      } else {
        tree = SplitTree(leaf: pane.id)
      }
    }
    return Worktree(name: "main", path: "/repo", splitTree: tree, panes: panes, focusedPaneID: panes.first?.id)
  }

  // MARK: - Consistent layouts

  @Test
  func emptyWorktreeIsConsistent() throws {
    let worktree = Worktree(name: "w", path: "/w")
    #expect(worktree.isConsistent)
    try worktree.validateInvariants()
  }

  @Test
  func stackedAndSplitLayoutIsConsistent() throws {
    let left = Pane(tabs: [terminalTab("/a"), terminalTab("/b")])
    let right = Pane(tabs: [terminalTab("/c")])
    let worktree = try worktree([left, right])
    #expect(worktree.isConsistent)
    try worktree.validateInvariants()
    #expect(left.selectedTabID == left.tabs.first?.id)
    #expect(worktree.focusedPaneID == left.id)
  }

  // MARK: - Each violation

  @Test
  func duplicatePaneIDsAreRejected() throws {
    let pane = Pane(tabs: [terminalTab()])
    let worktree = Worktree(
      name: "w", path: "/w", splitTree: SplitTree(leaf: pane.id), panes: [pane, pane], focusedPaneID: pane.id)
    #expect(!worktree.isConsistent)
    #expect(throws: Worktree.InvariantError.duplicatePaneIDs) { try worktree.validateInvariants() }
  }

  @Test
  func leavesMustMatchPanes() throws {
    let pane = Pane(tabs: [terminalTab()])
    let stray = Pane(tabs: [terminalTab()])
    let worktree = Worktree(
      name: "w", path: "/w", splitTree: SplitTree(leaf: pane.id), panes: [pane, stray], focusedPaneID: pane.id)
    #expect(!worktree.isConsistent)
    #expect(
      throws: Worktree.InvariantError.leavesDoNotMatchPanes(leaves: [pane.id], panes: [pane.id, stray.id])
    ) { try worktree.validateInvariants() }
  }

  @Test
  func emptyPaneIsRejected() throws {
    var pane = Pane(tabs: [terminalTab()])
    pane.tabs = []
    pane.selectedTabID = nil
    let worktree = Worktree(
      name: "w", path: "/w", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
    #expect(!worktree.isConsistent)
    #expect(throws: Worktree.InvariantError.emptyPane(pane.id)) { try worktree.validateInvariants() }
  }

  @Test
  func selectionMustResolveInsideItsPane() throws {
    var pane = Pane(tabs: [terminalTab()])
    pane.selectedTabID = TabID()
    let dangling = Worktree(
      name: "w", path: "/w", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
    #expect(throws: Worktree.InvariantError.unresolvedSelection(pane.id)) { try dangling.validateInvariants() }

    pane.selectedTabID = nil
    let unset = Worktree(
      name: "w", path: "/w", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
    #expect(throws: Worktree.InvariantError.unresolvedSelection(pane.id)) { try unset.validateInvariants() }
  }

  @Test
  func focusExistsIffPanesExist() throws {
    let pane = Pane(tabs: [terminalTab()])
    var unfocused = try worktree([pane])
    unfocused.focusedPaneID = nil
    #expect(throws: Worktree.InvariantError.missingFocus) { try unfocused.validateInvariants() }

    var dangling = try worktree([pane])
    dangling.focusedPaneID = PaneID()
    #expect(throws: Worktree.InvariantError.danglingFocus(dangling.focusedPaneID!)) {
      try dangling.validateInvariants()
    }

    let focusWithoutPanes = Worktree(name: "w", path: "/w", focusedPaneID: pane.id)
    #expect(throws: Worktree.InvariantError.danglingFocus(pane.id)) { try focusWithoutPanes.validateInvariants() }
  }

  @Test
  func tabIDsAreUniquePerWorktree() throws {
    let tab = terminalTab()
    var twin = tab
    twin.content = .terminal(workingDirectory: "/other")
    let worktree = try worktree([Pane(tabs: [tab]), Pane(tabs: [twin])])
    #expect(throws: Worktree.InvariantError.duplicateTabIDs) { try worktree.validateInvariants() }
  }

  @Test
  func contentIDsAreUniquePerWorktree() throws {
    let tab = terminalTab()
    let twin = Tab(content: tab.content)
    let worktree = try worktree([Pane(tabs: [tab, twin])])
    #expect(throws: Worktree.InvariantError.duplicateContentIDs) { try worktree.validateInvariants() }
  }
}
