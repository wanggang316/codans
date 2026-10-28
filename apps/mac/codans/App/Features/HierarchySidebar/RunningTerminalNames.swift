import CodansCore

/// Display names of the terminals (tabs) of a row that are running
/// something, for confirmations that stop them.
enum RunningTerminalNames {
  static func names(in row: Worktree, isRunning: (Tab) -> Bool) -> [String] {
    row.allTabs.enumerated().compactMap { index, tab in
      guard isRunning(tab) else { return nil }
      let title = tab.name ?? tab.cachedDisplayTitle ?? "Tab \(index + 1)"
      return "\(row.name) › \(title)"
    }
  }
}
