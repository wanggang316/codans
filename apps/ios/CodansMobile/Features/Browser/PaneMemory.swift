import Foundation

/// The pane last viewed in each worktree, so opening a worktree lands where
/// the user left it. Kept per scene in `@SceneStorage`, which stores only
/// plain values, hence the string encoding.
nonisolated struct PaneMemory: Equatable {
  private(set) var panes: [String: String] = [:]

  /// Worktrees remembered at most; the oldest entries go first.
  static let limit = 64

  private var order: [String] = []

  init() {}

  init(encoded: String) {
    guard let data = encoded.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Stored.self, from: data)
    else { return }
    panes = decoded.panes
    order = decoded.order.filter { decoded.panes[$0] != nil }
  }

  var encoded: String {
    guard let data = try? JSONEncoder().encode(Stored(panes: panes, order: order)) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  func pane(inWorktree worktreeID: String) -> String? {
    panes[worktreeID]
  }

  mutating func remember(pane paneID: String, inWorktree worktreeID: String) {
    panes[worktreeID] = paneID
    order.removeAll { $0 == worktreeID }
    order.append(worktreeID)
    while order.count > Self.limit {
      panes[order.removeFirst()] = nil
    }
  }

  private struct Stored: Codable {
    let panes: [String: String]
    let order: [String]
  }
}
