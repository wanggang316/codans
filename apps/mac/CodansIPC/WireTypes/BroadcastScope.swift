import Foundation
import CodansCore

extension IPC {
  /// Fan-out scope for `terminal.broadcastInput`. Three kinds:
  /// tab / worktree / label. Encoded as a tagged union
  /// `{ "kind": String, "target": String }`.
  public struct BroadcastScope: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
      case tab, worktree, label
    }

    public let kind: Kind
    /// UUID string for id-based kinds (`tab`, `worktree`) or a label string
    /// for `label`.
    public let target: String

    public init(kind: Kind, target: String) {
      self.kind = kind
      self.target = target
    }

    public static func tab(_ id: TabID) -> BroadcastScope { .init(kind: .tab, target: id.description) }
    public static func worktree(_ id: WorktreeID) -> BroadcastScope { .init(kind: .worktree, target: id.description) }
    public static func label(_ label: String) -> BroadcastScope { .init(kind: .label, target: label) }
  }
}
