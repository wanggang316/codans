import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Pure tests for `HierarchySidebarView.orderedSidebarRows(project:pendings:)` — the
/// segment-merge function that decides which rows render in what order. No `TestStore`
/// here: the function is a `static` over plain values, so a focused file keeps it
/// independent of the reducer test surface.
@MainActor
struct HierarchySidebarOrderingTests {

  // MARK: - Builders

  private static func worktree(
    name: String,
    path: String,
    isPinned: Bool = false,
    archived: Bool = false
  ) -> Worktree {
    Worktree(name: name, path: path, archived: archived, isPinned: isPinned)
  }

  private static func project(
    rootPath: String = "/repo/main",
    worktrees: [Worktree]
  ) -> Project {
    Project(name: "p", rootPath: rootPath, worktrees: worktrees)
  }

  private static func makeSpec() -> CreateWorktreeSpec {
    CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      name: "feature-x",
      baseRef: "origin/main",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
  }

  private static func pending(
    projectID: ProjectID,
    name: String
  ) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(),
      projectID: projectID,
      spec: makeSpec(),
      displayName: name,
      status: .running,
      lastProgressLine: nil,
      startedAt: Date(timeIntervalSince1970: 0)
    )
  }

  // MARK: - Tests

  @Test
  func returnsSixRowsAndCorrectSegmentOrder() {
    // 1 main + 2 pinned + 3 unpinned + 0 pending
    let main = Self.worktree(name: "main", path: "/repo/main")
    let pin1 = Self.worktree(name: "pin1", path: "/repo/pin1", isPinned: true)
    let pin2 = Self.worktree(name: "pin2", path: "/repo/pin2", isPinned: true)
    let un1 = Self.worktree(name: "un1", path: "/repo/un1")
    let un2 = Self.worktree(name: "un2", path: "/repo/un2")
    let un3 = Self.worktree(name: "un3", path: "/repo/un3")
    let project = Self.project(worktrees: [main, pin1, un1, pin2, un2, un3])

    let rows = HierarchySidebarView.orderedSidebarRows(project: project, pendings: [])

    #expect(rows.count == 6)
    #expect(
      rows.map(\.id) == [
        "wt:\(main.id.raw)",
        "wt:\(pin1.id.raw)",
        "wt:\(pin2.id.raw)",
        "wt:\(un1.id.raw)",
        "wt:\(un2.id.raw)",
        "wt:\(un3.id.raw)",
      ])
  }

  @Test
  func placesPendingBetweenPinnedAndUnpinned() {
    // 1 main + 1 pinned + 2 pending (matching project) + 2 unpinned
    let projectID = ProjectID()
    let main = Self.worktree(name: "main", path: "/repo/main")
    let pin = Self.worktree(name: "pin", path: "/repo/pin", isPinned: true)
    let un1 = Self.worktree(name: "un1", path: "/repo/un1")
    let un2 = Self.worktree(name: "un2", path: "/repo/un2")
    let project = Project(
      id: projectID,
      name: "p",
      rootPath: "/repo/main",
      worktrees: [main, pin, un1, un2]
    )
    let pend1 = Self.pending(projectID: projectID, name: "feat/a")
    let pend2 = Self.pending(projectID: projectID, name: "feat/b")

    let rows = HierarchySidebarView.orderedSidebarRows(
      project: project,
      pendings: [pend1, pend2]
    )

    #expect(rows.count == 6)
    let ids = rows.map(\.id)
    #expect(ids[0] == "wt:\(main.id.raw)")
    #expect(ids[1] == "wt:\(pin.id.raw)")
    #expect(ids[2] == "pending:\(pend1.id.raw)")
    #expect(ids[3] == "pending:\(pend2.id.raw)")
    #expect(ids[4] == "wt:\(un1.id.raw)")
    #expect(ids[5] == "wt:\(un2.id.raw)")
  }

  @Test
  func filtersOutOtherProjectPending() {
    let projectID = ProjectID()
    let otherID = ProjectID()
    let main = Self.worktree(name: "main", path: "/repo/main")
    let project = Project(id: projectID, name: "p", rootPath: "/repo/main", worktrees: [main])
    let mine = Self.pending(projectID: projectID, name: "mine")
    let theirs = Self.pending(projectID: otherID, name: "theirs")

    let rows = HierarchySidebarView.orderedSidebarRows(
      project: project,
      pendings: [theirs, mine]
    )

    #expect(rows.count == 2)
    #expect(rows.map(\.id) == ["wt:\(main.id.raw)", "pending:\(mine.id.raw)"])
  }

  @Test
  func excludesArchivedFromAllSegments() {
    let main = Self.worktree(name: "main", path: "/repo/main")
    let pinKept = Self.worktree(name: "pin1", path: "/repo/pin1", isPinned: true)
    let pinArchived = Self.worktree(
      name: "pin-arch", path: "/repo/pin-arch", isPinned: true, archived: true
    )
    let unKept = Self.worktree(name: "un1", path: "/repo/un1")
    let unArchived = Self.worktree(
      name: "un-arch", path: "/repo/un-arch", archived: true
    )
    let project = Self.project(
      worktrees: [main, pinKept, pinArchived, unKept, unArchived]
    )

    let rows = HierarchySidebarView.orderedSidebarRows(project: project, pendings: [])

    #expect(rows.count == 3)
    #expect(
      rows.map(\.id) == [
        "wt:\(main.id.raw)",
        "wt:\(pinKept.id.raw)",
        "wt:\(unKept.id.raw)",
      ])
  }
}
