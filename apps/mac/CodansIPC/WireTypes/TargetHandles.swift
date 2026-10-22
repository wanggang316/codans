import Foundation

extension IPC {
  /// Short-handle map attached to `hierarchy.listProjects` responses.
  /// Keys are `UUID().uuidString` — a `[UUID: Int]` dictionary would
  /// encode as a flat key/value array under Codable — and values are the
  /// app-session handles the CLI prints: `panes` maps Pane ids to `p<n>`,
  /// `tabs` maps Tab ids to `t<n>`.
  public struct TargetHandles: Codable, Equatable, Sendable {
    public let panes: [String: Int]
    public let tabs: [String: Int]

    public init(panes: [String: Int], tabs: [String: Int]) {
      self.panes = panes
      self.tabs = tabs
    }
  }
}
