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
    let tabA1Active = TabID()
    let tabA1Inactive = TabID()
    let paneA1ActiveTabFocused = PaneID()
    let paneA1ActiveTabUnfocused = PaneID()
  }

  private func entry(
    kind: InboxEntry.Kind = .taskFinished,
    project: ProjectID,
    worktree: WorktreeID,
    tab: TabID,
    pane: PaneID
  ) -> InboxEntry {
    InboxEntry(
      kind: kind,
      title: "t",
      body: "b",
      source: InboxEntry.SourcePath(
        projectID: project,
        worktreeID: worktree,
        tabID: tab,
        paneID: pane
      )
    )
  }

  // MARK: - Visibility rule (one source, varying focus)

  @Test
  func projectCollapsedRollsToProjectLevel() {
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Active, pane: p.paneA1ActiveTabFocused)
    ]
    // Project A is NOT in expandedProjectIDs.
    let focus = RollupFocusState(expandedProjectIDs: [])
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects == [p.projectA])
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadTabs.isEmpty)
  }

  @Test
  func projectExpandedButNotActiveRollsToWorktree() {
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Active, pane: p.paneA1ActiveTabFocused)
    ]
    let focus = RollupFocusState(
      activeProjectID: p.projectB,    // user is on a different project
      expandedProjectIDs: [p.projectA, p.projectB]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees == [p.worktreeA1])
    #expect(index.unreadTabs.isEmpty)
  }

  @Test
  func worktreeNotActiveRollsToWorktree() {
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA2, tab: p.tabA1Active, pane: p.paneA1ActiveTabFocused)
    ]
    // Project A active, but A2 isn't the active worktree (A1 is).
    let focus = RollupFocusState(
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadWorktrees == [p.worktreeA2])
    #expect(index.unreadTabs.isEmpty)
  }

  @Test
  func tabInactiveRollsToTab() {
    let p = Pathset()
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Inactive, pane: p.paneA1ActiveTabFocused)
    ]
    let focus = RollupFocusState(
      activeTabID: p.tabA1Active,
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadTabs == [p.tabA1Inactive])
  }

  // MARK: - Pane-level sink (active tab → no roll-up indicator)

  @Test
  func unfocusedPaneInActiveTabIsSink() {
    // A sibling split in the active tab: visible to the user, so the entry
    // emits no roll-up indicator at any level. It still counts as unread.
    let p = Pathset()
    let unread = [
      entry(
        kind: .taskFinished,
        project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Active,
        pane: p.paneA1ActiveTabUnfocused
      )
    ]
    let focus = RollupFocusState(
      focusedPaneID: p.paneA1ActiveTabFocused,
      activeTabID: p.tabA1Active,
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadTabs.isEmpty)
    #expect(index.globalUnreadCount == 1)
  }

  @Test
  func focusedPaneIsSink() {
    // The user is looking directly at the source pane. No chrome lights up;
    // the entry stays unread (cleared later by R1's mark-read on focus).
    let p = Pathset()
    let pane = p.paneA1ActiveTabFocused
    let unread = [
      entry(kind: .waitingForInput, project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Active, pane: pane)
    ]
    let focus = RollupFocusState(
      focusedPaneID: pane,
      activeTabID: p.tabA1Active,
      activeWorktreeID: p.worktreeA1,
      activeProjectID: p.projectA,
      expandedProjectIDs: [p.projectA]
    )
    let index = RollupIndex.compute(unread: unread, focus: focus)

    #expect(index.unreadProjects.isEmpty)
    #expect(index.unreadWorktrees.isEmpty)
    #expect(index.unreadTabs.isEmpty)
    #expect(index.globalUnreadCount == 1)
  }

  // MARK: - Aggregate

  @Test
  func globalUnreadCountTotalsEverythingRegardlessOfRollup() {
    let p = Pathset()
    // Five unread spread across projects / worktrees / tabs / panes.
    let unread = [
      entry(project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Active, pane: p.paneA1ActiveTabFocused),
      entry(project: p.projectA, worktree: p.worktreeA1, tab: p.tabA1Inactive, pane: PaneID()),
      entry(project: p.projectA, worktree: p.worktreeA2, tab: TabID(), pane: PaneID()),
      entry(project: p.projectB, worktree: p.worktreeB1, tab: TabID(), pane: PaneID()),
      entry(project: p.projectB, worktree: p.worktreeB1, tab: TabID(), pane: PaneID()),
    ]
    let focus = RollupFocusState(
      focusedPaneID: p.paneA1ActiveTabFocused,
      activeTabID: p.tabA1Active,
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
