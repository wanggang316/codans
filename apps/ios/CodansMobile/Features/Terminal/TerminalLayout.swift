import CodansIPC
import ComposableArchitecture
import Foundation
import GameController

/// How a tab's panes map onto the phone: split order for the menu, page
/// dots and swipes, and which panes the iPad streams.
nonisolated enum TerminalLayout {
  /// Panes in split order — left to right, top to bottom, as on the Mac.
  /// Panes the layout does not mention (an older Mac, an unknown node)
  /// follow in list order; layout leaves with no pane are dropped.
  static func orderedPaneIDs(in tab: IPC.TabSummary) -> [String] {
    let listed = tab.panes.map(\.id)
    let known = Set(listed)
    var ordered: [String] = []
    for id in tab.layout?.paneIDs ?? [] where known.contains(id) && !ordered.contains(id) {
      ordered.append(id)
    }
    ordered.append(contentsOf: listed.filter { !ordered.contains($0) })
    return ordered
  }

  /// The pane `offset` places from `paneID` in split order, wrapping.
  static func pane(_ offset: Int, from paneID: String, in tab: IPC.TabSummary) -> String? {
    let ordered = orderedPaneIDs(in: tab)
    guard let index = ordered.firstIndex(of: paneID), ordered.count > 1 else { return nil }
    let count = ordered.count
    return ordered[((index + offset) % count + count) % count]
  }

  /// The pane a tab opens on: the Mac's focused pane, else the first.
  static func landingPane(in tab: IPC.TabSummary) -> String? {
    if let focused = tab.focusedPaneID, tab.panes.contains(where: { $0.id == focused }) { return focused }
    return orderedPaneIDs(in: tab).first
  }

  /// The pane a worktree opens on: the one last viewed on this device,
  /// else the Mac's selected tab's focused pane, else the first pane.
  static func landingPane(in worktree: IPC.WorktreeSummary, remembered: String?) -> String? {
    if let remembered, worktree.tabs.contains(where: { $0.panes.contains { $0.id == remembered } }) {
      return remembered
    }
    if let tab = worktree.tabs.first(where: { $0.id == worktree.selectedTabID }), let pane = landingPane(in: tab) {
      return pane
    }
    return worktree.tabs.lazy.compactMap(landingPane).first
  }

  /// Panes that get a live stream on the iPad: the first `limit` in split
  /// order, always including the focused one.
  static func streamedPaneIDs(in tab: IPC.TabSummary, focused: String?, limit: Int = 4) -> Set<String> {
    var ids = Array(orderedPaneIDs(in: tab).prefix(limit))
    if let focused, !ids.contains(focused), tab.panes.contains(where: { $0.id == focused }) {
      ids.removeLast()
      ids.append(focused)
    }
    return Set(ids)
  }

  /// Where to go after the pane on screen closed: its neighbour in the
  /// same tab, else another tab's landing pane.
  static func paneAfterClosing(_ paneID: String, in worktree: IPC.WorktreeSummary) -> String? {
    guard let tab = worktree.tabs.first(where: { $0.panes.contains { $0.id == paneID } }) else {
      return worktree.tabs.lazy.compactMap(landingPane).first
    }
    let ordered = orderedPaneIDs(in: tab)
    if let index = ordered.firstIndex(of: paneID) {
      let others = ordered.filter { $0 != paneID }
      if !others.isEmpty { return others[min(index, others.count - 1)] }
    }
    return worktree.tabs.lazy.filter { $0.id != tab.id }.compactMap(landingPane).first
  }

  /// A working directory with the home folder shortened to `~`.
  static func displayPath(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if parts.count >= 3, parts[1] == "Users" {
      let rest = parts.dropFirst(3).joined(separator: "/")
      return rest.isEmpty ? "~" : "~/\(rest)"
    }
    return path
  }
}

/// One `TerminalStreamFeature` store per pane on screen, per scene. Kept
/// outside the views so a pane keeps its screen while SwiftUI rebuilds
/// them; a pane that leaves the screen is dropped, which cancels its
/// stream.
@MainActor
final class TerminalStoreCache {
  private var stores: [String: StoreOf<TerminalStreamFeature>] = [:]

  func store(
    for paneID: String, permission: IPC.RemotePermission, isConnected: Bool
  ) -> StoreOf<TerminalStreamFeature> {
    if let store = stores[paneID] { return store }
    let store = Store(
      initialState: TerminalStreamFeature.State(paneID: paneID, permission: permission, isConnected: isConnected)
    ) {
      TerminalStreamFeature()
    } withDependencies: {
      #if DEBUG
        // A pane store starts from the live dependencies, not the app
        // store's; the demo Mac has to reach it too.
        if DemoMode.isEnabled { DemoMode.apply(to: &$0) }
      #endif
    }
    stores[paneID] = store
    return store
  }

  var all: [StoreOf<TerminalStreamFeature>] { Array(stores.values) }

  func retain(only paneIDs: Set<String>) {
    stores = stores.filter { paneIDs.contains($0.key) }
  }
}

/// Whether a hardware keyboard is attached; the key bar hides while one
/// is.
@MainActor
@Observable
final class HardwareKeyboardMonitor {
  private(set) var isConnected = GCKeyboard.coalesced != nil
  /// Written only in `init`; read in `deinit`, which is nonisolated.
  @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
        })
    }
  }

  // Explicit and nonisolated: a synthesized isolated deinit on a
  // SwiftUI-owned observable has crashed on release.
  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}
