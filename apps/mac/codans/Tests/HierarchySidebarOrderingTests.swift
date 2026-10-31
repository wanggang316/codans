import CodansCore
import Foundation
import Testing

@testable import Codans

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

  /// A git Project: its main checkout is a row under the Project row.
  private static func project(
    rootPath: String = "/repo/main",
    worktrees: [Worktree]
  ) -> Project {
    Project(name: "p", rootPath: rootPath, gitRoot: rootPath, worktrees: worktrees)
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
      gitRoot: "/repo/main",
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
  func aFolderProjectListsNoRowForItsRoot() {
    // The Project row itself stands for a folder's root. (A workspace lists
    // its groups instead: `Project.workspaceSidebarRows`.)
    let root = Self.worktree(name: "notes", path: "/notes")
    let folder = Project(name: "notes", rootPath: "/notes", worktrees: [root])

    #expect(HierarchySidebarView.orderedSidebarRows(project: folder, pendings: []).isEmpty)
  }

  @Test
  func filtersOutOtherProjectPending() {
    let projectID = ProjectID()
    let otherID = ProjectID()
    let main = Self.worktree(name: "main", path: "/repo/main")
    let project = Project(id: projectID, name: "p", rootPath: "/repo/main", gitRoot: "/repo/main", worktrees: [main])
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

@MainActor
struct SidebarFilterLayoutTests {
  @Test
  func transitionsKeepEveryGapAndBothOuterEdges() {
    for width: CGFloat in [220, 260, 320] {
      for from in SidebarFilter.allCases {
        for to in SidebarFilter.allCases {
          let start = SidebarFilterExpansion(selection: from)
          let end = SidebarFilterExpansion(selection: to)
          for step in 0...100 {
            checkFrames(blend(start, end, Double(step) / 100), width: width)
          }
          let interrupted = blend(start, end, 0.37)
          for next in SidebarFilter.allCases {
            for step in 0...20 {
              checkFrames(
                blend(interrupted, SidebarFilterExpansion(selection: next), Double(step) / 20),
                width: width
              )
            }
          }
        }
      }
    }
  }

  @Test
  func collapsedCapsulesStayRoundWhenNarrow() {
    let count = CGFloat(SidebarFilter.allCases.count)
    for width: CGFloat in [120, 160, 200, 240] {
      let layout = SidebarFilterLayout(expansion: SidebarFilterExpansion(selection: .workspace), height: 34)
      let frames = layout.frames(width: width)
      let diameter = min(34, (width - 6 * (count - 1)) / count)
      for (filter, frame) in zip(SidebarFilter.allCases, frames) {
        #expect(abs(frame.height - diameter) < 0.000001)
        #expect(abs(frame.midY - 17) < 0.000001)
        if filter != .workspace {
          #expect(abs(frame.width - diameter) < 0.000001)
        } else {
          #expect(frame.width >= diameter - 0.000001)
        }
      }
    }
  }

  private func blend(
    _ from: SidebarFilterExpansion, _ to: SidebarFilterExpansion, _ progress: Double
  ) -> SidebarFilterExpansion {
    var delta = to - from
    delta.scale(by: progress)
    return from + delta
  }

  private func checkFrames(_ expansion: SidebarFilterExpansion, width: CGFloat) {
    let frames = SidebarFilterLayout(expansion: expansion, height: 28).frames(width: width)
    #expect(frames.count == SidebarFilter.allCases.count)
    #expect(frames.first?.minX == 0)
    #expect(abs((frames.last?.maxX ?? 0) - width) < 0.000001)
    for (left, right) in zip(frames, frames.dropFirst()) {
      #expect(abs(right.minX - left.maxX - 6) < 0.000001)
      #expect(left.width > 0)
    }
  }
}
