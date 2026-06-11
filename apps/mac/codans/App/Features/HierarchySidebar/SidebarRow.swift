import Foundation
import CodansCore

/// Heterogeneous sidebar row. The pinned/unpinned segments render real
/// `Worktree`s from the catalog; the pending segment renders in-memory
/// `PendingWorktree`s while `wt sw` streams. `id` carries an explicit
/// case prefix so two UUID-backed identifiers cannot collide inside a
/// SwiftUI `ForEach`.
enum SidebarRow: Identifiable {
  case worktree(Worktree)
  case pending(PendingWorktree)

  var id: String {
    switch self {
    case .worktree(let w): return "wt:\(w.id.raw)"
    case .pending(let p): return "pending:\(p.id.raw)"
    }
  }
}
