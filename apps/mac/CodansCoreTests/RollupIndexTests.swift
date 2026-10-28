import Foundation
import Testing

@testable import CodansCore

struct RollupIndexTests {
  // MARK: - Fixtures

  struct Pathset {
    let projectA = ProjectID()
    let projectB = ProjectID()
    let worktreeA1 = WorktreeID()
    let worktreeA2 = WorktreeID()
    let worktreeB1 = WorktreeID()
    /// Selected Tab of the focused Pane in A1.
    let contentA1Shown = ContentID()
    /// Selected Tab of another Pane in A1: on screen, not focused.
    let contentA1Sibling = ContentID()
    /// A Tab stacked behind the selected one.
    let contentA1Hidden = ContentID()
  }

  private func entry(
    kind: InboxEntry.Kind = .taskFinished,
    project: ProjectID,
    worktree: WorktreeID,
    content: ContentID
  ) -> InboxEntry {
    InboxEntry(
      kind: kind,
      title: "t",
      body: "b",
      source: InboxEntry.SourcePath(projectID: project, worktreeID: worktree, contentID: content)
    )
  }

  // MARK: - Visibility rule (one source, varying focus)

  @Test
  func projectCollapsedRollsToProjectLevel() {
    let p = Pathset()
    let unread = [entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Shown)]
    // Project A is NOT in expandedProjectIDs.
    let focus = RollupFocusState(expandedProjectIDs: [])
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects == [p.projectA])
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadContents.isEmpty)
  }

  @Test
  func aProjectRowsOwnWorktreeStaysVisibleWhileCollapsed() {
    // A folder or workspace Project row stands for its root worktree, so
    // collapsing the Project hides only the rows under it.
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Shown),
      entry(project: p.projectA, worktree: p.worktreeA2, content: p.contentA1Hidden)
    ]
    let focus = RollupFocusState(
      activeProjectID: p.projectB, expandedProjectIDs: [], rowWorktreeIDs: [p.worktreeA1])
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadWorktrees == [p.worktreeA1])
    #expect(index.unreadProjects == [p.projectA])
  }

  @Test
  func aRowInACollapsedGroupRollsToItsGroupRow() {
    // worktreeA2 sits in a collapsed Workspace group whose row is worktreeA1.
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA2, content: p.contentA1Hidden)
    ]
    let focus = RollupFocusState(
      activeProjectID: p.projectB, expandedProjectIDs: [p.projectA], rowStandIns: [p.worktreeA2: p.worktreeA1])
    #expect(RollupIndex.compute(unread: unread, focus: focus).unreadWorktrees == [p.worktreeA1])

    // A collapsed Workspace still rolls everything up to its header.
    let collapsed = RollupFocusState(
      activeProjectID: p.projectB, expandedProjectIDs: [], rowStandIns: [p.worktreeA2: p.worktreeA1])
    let index = RollupIndex.compute(unread: unread, focus: collapsed)
    #expect(index.unreadProjects == [p.projectA])
    #expect(index.unreadWorktrees.isEmpty)
  }

  @Test
  func projectExpandedButNotActiveRollsToWorktree() {
    let p = Pathset()
    let unread = [entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Shown)]
    let focus = RollupFocusState(
      activeProjectID: p.projectB,  // user is on a different project
      expandedProjectIDs: [p.projectA, p.projectB]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees == [p.worktreeA1])
    #expect(index.unreadContents.isEmpty)
  }

  @Test
  func worktreeNotActiveRollsToWorktree() {
    let p = Pathset()
    let unread = [entry(project: p.projectA, worktree: p.worktreeA2, content: p.contentA1Shown)]
    // Project A active, but A2 isn't the active worktree (A1 is).
    let focus = RollupFocusState(
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadWorktrees == [p.worktreeA2])
    #expect(index.unreadContents.isEmpty)
  }

  @Test
  func tabStackedBehindTheSelectedOneRollsToTab() {
    let p = Pathset()
    let unread = [entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Hidden)]
    let focus = RollupFocusState(
      visibleContentIDs: [p.contentA1Shown, p.contentA1Sibling],
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadContents == [p.contentA1Hidden])
  }

  // MARK: - Content-level sink (on screen → no roll-up indicator)

  @Test
  func selectedTabOfAnUnfocusedPaneIsSink() {
    // The selected Tab of a sibling Pane is on screen, so the entry emits
    // no roll-up indicator at any level. It still counts as unread.
    let p = Pathset()
    let unread = [
      entry(kind: .taskFinished, project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Sibling)
    ]
    let focus = RollupFocusState(
      visibleContentIDs: [p.contentA1Shown, p.contentA1Sibling],
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadContents.isEmpty)
    #expect(index.globalUnreadCount == 1)
  }

  @Test
  func selectedTabOfTheFocusedPaneIsSink() {
    // The user is looking directly at the source Content. No chrome lights
    // up; the entry stays unread (cleared later by mark-read on focus).
    let p = Pathset()
    let unread = [
      entry(kind: .waitingForInput, project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Shown)
    ]
    let focus = RollupFocusState(
      visibleContentIDs: [p.contentA1Shown],
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadContents.isEmpty)
    #expect(index.globalUnreadCount == 1)
  }

  // MARK: - Aggregate

  @Test
  func globalUnreadCountTotalsEverythingRegardlessOfRollup() {
    let p = Pathset()
    // Five unread spread across projects / worktrees / Tabs.
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Shown),
      entry(project: p.projectA, worktree: p.worktreeA1, content: p.contentA1Hidden),
      entry(project: p.projectA, worktree: p.worktreeA2, content: ContentID()),
      entry(project: p.projectB, worktree: p.worktreeB1, content: ContentID()),
      entry(project: p.projectB, worktree: p.worktreeB1, content: ContentID())
    ]
    let focus = RollupFocusState(
      visibleContentIDs: [p.contentA1Shown],
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)
    #expect(index.globalUnreadCount == 5)
  }

  @Test
  func emptyUnreadYieldsEmptyIndex() {
    let index = RollupIndex.compute(unread: [], focus: RollupFocusState())
    #expect(index == .empty)
  }
}
