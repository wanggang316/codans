import CodansCore
import Testing

@testable import Codans

struct WorktreeSelectionHistoryTests {
  @Test
  func latestSelectionRanksFirst() {
    let (a, b) = (WorktreeID(), WorktreeID())
    var history = WorktreeSelectionHistory(limit: 3)
    history.record(a)
    history.record(b)
    #expect(history.rank(of: b) == 0)
    #expect(history.rank(of: a) == 1)
  }

  @Test
  func reselectionMovesToFrontWithoutDuplicates() {
    let (a, b) = (WorktreeID(), WorktreeID())
    var history = WorktreeSelectionHistory(limit: 3)
    history.record(a)
    history.record(b)
    history.record(a)
    #expect(history.worktrees == [a, b])
  }

  @Test
  func oldestSelectionDropsOutPastTheLimit() {
    let ids = (0..<4).map { _ in WorktreeID() }
    var history = WorktreeSelectionHistory(limit: 3)
    for id in ids { history.record(id) }
    #expect(history.rank(of: ids[0]) == nil)
    #expect(history.worktrees == [ids[3], ids[2], ids[1]])
  }

  @Test
  func unknownWorktreeHasNoRank() {
    #expect(WorktreeSelectionHistory(limit: 3).rank(of: WorktreeID()) == nil)
  }
}
