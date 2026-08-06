import Foundation

extension IPC {
  /// Short-handle map attached to `hierarchy.listProjects` responses.
  /// Keys are `UUID().uuidString` — a `[UUID: Int]` dictionary would
  /// encode as a flat key/value array under Codable — and values are the
  /// app-session handles the CLI prints as `t<n>` / `p<n>`. The field is
  /// optional on both payload ends so old/new app–CLI pairs interoperate:
  /// an old app omits it, an old CLI ignores it.
  public struct TargetHandles: Codable, Equatable, Sendable {
    public let tabs: [String: Int]
    public let panes: [String: Int]

    public init(tabs: [String: Int], panes: [String: Int]) {
      self.tabs = tabs
      self.panes = panes
    }
  }
}
