import CodansCore
import Testing

@testable import Codans

/// The sidebar's native List selection covers both worktree rows and the
/// followed in-flight creation, so both get the same system highlight.
struct SidebarSelectionTests {
  @Test func followedCreationIsSelectedWhenNoWorktreeIs() {
    let pendingID = PendingWorktreeID()
    #expect(
      SidebarSelection.resolve(selectedWorktreeID: nil, activePendingWorktreeID: pendingID)
        == .pending(pendingID))
  }

  @Test func selectedWorktreeWinsOverFollowedCreation() {
    let worktreeID = WorktreeID()
    #expect(
      SidebarSelection.resolve(
        selectedWorktreeID: worktreeID, activePendingWorktreeID: PendingWorktreeID())
        == .worktree(worktreeID))
  }

  @Test func nothingSelected() {
    #expect(
      SidebarSelection.resolve(selectedWorktreeID: nil, activePendingWorktreeID: nil) == nil)
  }
}
