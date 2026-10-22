import CodansCore
import CodansIPC
import Foundation

/// App-lifetime registry that backs the CLI's short target handles
/// (`p<n>` for Panes, `t<n>` for Tabs). Handles are monotonically
/// increasing integers assigned per kind on first sight, stay stable for
/// as long as the entity lives, and are released when the entity leaves
/// the catalog. The counters never rewind, so a released handle is never
/// reissued to a different entity within one app session — a stale
/// handle in a script fails with not-found instead of hitting the wrong
/// target.
///
/// Handles are session-scoped convenience sugar on top of the canonical
/// UUID identifiers: `hierarchy.resolveAlias` turns them into UUIDs
/// before any mutation, and JSON output carries UUIDs only.
@MainActor
final class TargetHandleRegistry {
  private var tabHandles: [TabID: Int] = [:]
  private var paneHandles: [PaneID: Int] = [:]
  private var nextTabHandle = 1
  private var nextPaneHandle = 1

  /// Bring the handle maps in line with `catalog`: assign the next
  /// handle to unseen Panes / Tabs in hierarchy order (Panes in split-tree
  /// leaf order, then each Pane's Tabs in strip order) and drop entries
  /// whose ids are gone. Called before every read or lookup, so first
  /// assignment order matches what `codans tree` prints even when a
  /// handle is resolved before any listing ran.
  func sync(with catalog: Catalog) {
    var liveTabs: Set<TabID> = []
    var livePanes: Set<PaneID> = []
    for project in catalog.projects {
      for worktree in project.worktrees {
        for pane in Self.panesInLayoutOrder(worktree) {
          livePanes.insert(pane.id)
          if paneHandles[pane.id] == nil {
            paneHandles[pane.id] = nextPaneHandle
            nextPaneHandle += 1
          }
          for tab in pane.tabs {
            liveTabs.insert(tab.id)
            if tabHandles[tab.id] == nil {
              tabHandles[tab.id] = nextTabHandle
              nextTabHandle += 1
            }
          }
        }
      }
    }
    tabHandles = tabHandles.filter { liveTabs.contains($0.key) }
    paneHandles = paneHandles.filter { livePanes.contains($0.key) }
  }

  /// Panes as the layout shows them, left-to-right / top-to-bottom; a Pane
  /// missing from the tree (never, by invariant) trails in array order.
  static func panesInLayoutOrder(_ worktree: Worktree) -> [Pane] {
    let leaves = worktree.splitTree.leaves()
    let ordered = leaves.compactMap { worktree.pane($0) }
    let seen = Set(leaves)
    return ordered + worktree.panes.filter { !seen.contains($0.id) }
  }

  func tab(forHandle handle: Int) -> TabID? {
    tabHandles.first(where: { $0.value == handle })?.key
  }

  func pane(forHandle handle: Int) -> PaneID? {
    paneHandles.first(where: { $0.value == handle })?.key
  }

  func handle(forTab tabID: TabID) -> Int? {
    tabHandles[tabID]
  }

  func handle(forPane paneID: PaneID) -> Int? {
    paneHandles[paneID]
  }

  /// Wire-shaped snapshot for `hierarchy.listProjects` responses.
  func snapshot() -> IPC.TargetHandles {
    IPC.TargetHandles(
      panes: Dictionary(uniqueKeysWithValues: paneHandles.map { ($0.key.raw.uuidString, $0.value) }),
      tabs: Dictionary(uniqueKeysWithValues: tabHandles.map { ($0.key.raw.uuidString, $0.value) })
    )
  }

  /// Parse a short-handle selector (`t12` / `p3`). Strict shape: the
  /// lowercase kind prefix followed by digits only, so labels and project
  /// names can never collide with the handle namespace by accident.
  static func parse(_ value: String, prefix: Character) -> Int? {
    guard value.first == prefix else { return nil }
    let digits = value.dropFirst()
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
  }
}
