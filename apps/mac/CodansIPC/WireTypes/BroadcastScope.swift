import CodansCore
import Foundation

extension IPC {
  /// Fan-out scope for `terminal.broadcastInput`. Three kinds:
  /// pane (every Tab of that Pane) / worktree (every Tab of every Pane) /
  /// label (every Tab whose Content carries the label). Encoded as a
  /// tagged union `{ "kind": String, "target": String }`.
  public struct BroadcastScope: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
      case pane, worktree, label
    }

    public let kind: Kind
    /// UUID string for id-based kinds (`pane`, `worktree`) or a label
    /// string for `label`.
    public let target: String

    public init(kind: Kind, target: String) {
      self.kind = kind
      self.target = target
    }

    public static func pane(_ id: PaneID) -> BroadcastScope { .init(kind: .pane, target: id.description) }
    public static func worktree(_ id: WorktreeID) -> BroadcastScope { .init(kind: .worktree, target: id.description) }
    public static func label(_ label: String) -> BroadcastScope { .init(kind: .label, target: label) }
  }
}
