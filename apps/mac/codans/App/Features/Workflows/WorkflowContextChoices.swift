import CodansCore
import Foundation

struct WorkflowWorkspaceChoice: Identifiable {
  let id: WorktreeID
  let projectID: ProjectID
  let title: String
}

struct WorkflowPaneChoice: Identifiable {
  let id: PaneID
  let title: String
  let worktreeID: WorktreeID
}
