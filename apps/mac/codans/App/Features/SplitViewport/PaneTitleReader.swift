import CodansCore
import Foundation

/// Reads a `PaneTitle` inside a view body. The pane card header and the tab
/// chip both read it, so the chip shows the same text as the header of its
/// selected pane (ADR 0009).
@MainActor
enum PaneTitleReader {
  /// The pane title of `paneID` from its surface, or nil when the pane has
  /// no surface.
  static func liveTitle(
    paneID: PaneID, hierarchyManager: HierarchyManager, terminalClient: TerminalClient
  ) -> String? {
    guard let surface = terminalClient.surface(paneID) else { return nil }
    let info = surface.info
    // Read every input before resolving: a short-circuit would skip a read
    // and miss the next push on it.
    let lastTitle = info.lastTitle
    let pwd = info.pwd
    let isAtShellPrompt = hierarchyManager.paneIsAtShellPrompt(paneID)
    // Until the shell reports its directory again after a restart, the
    // persisted one stands in: the zmx daemon replays the title, not the
    // directory.
    let persisted = hierarchyManager.catalog.pane(paneID)?.workingDirectory
    return PaneTitle.resolve(
      isAtShellPrompt: isAtShellPrompt, lastTitle: lastTitle,
      workingDirectories: [pwd, persisted]) ?? PaneTitle.placeholder
  }

  /// The title of a pane with no surface: its persisted working directory.
  static func storedTitle(pane: Pane?) -> String? {
    PaneTitle.resolve(
      isAtShellPrompt: false, lastTitle: nil, workingDirectories: [pane?.workingDirectory])
  }

  /// The tab's cached title when it is the title of `selectedPaneID`. In a
  /// split tab the chip can mirror another pane after a restart (focus is
  /// not persisted), and that pane's header does not show the cached text.
  /// A cache from before the pane ID was stored counts only in a one-pane
  /// tab.
  nonisolated static func cachedTitle(of tab: Tab, selectedPaneID: PaneID?) -> String? {
    guard let selectedPaneID else { return nil }
    if let owner = tab.cachedDisplayTitlePaneID {
      return owner == selectedPaneID ? tab.cachedDisplayTitle : nil
    }
    return tab.panes.count <= 1 ? tab.cachedDisplayTitle : nil
  }

  /// What a pane card header shows.
  nonisolated static func headerTitle(live: String?, stored: String?) -> String {
    live ?? stored ?? PaneTitle.placeholder
  }

  /// What a tab chip shows: the tab name, else the header text of the
  /// selected pane. The cached title stands in only while that pane has no
  /// surface.
  nonisolated static func chipTitle(
    tabName: String?, live: String?, cached: String?, stored: String?, emptyTabTitle: String
  ) -> String {
    if let tabName, !tabName.isEmpty { return tabName }
    if let live { return live }
    if let cached, !cached.isEmpty { return cached }
    return stored ?? emptyTabTitle
  }
}
