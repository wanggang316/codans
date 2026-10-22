import CodansCore
import Foundation
import Observation
import os.log

/// Registry of live Content, keyed by `ContentID`, and the single path for
/// a Content's lifecycle (ADR-0002). Owns the `TabContent` instances —
/// creates one the first time a Content is brought up, drops it on close /
/// suspend — and keeps the chrome the strip's busy predicates read.
/// `HierarchyManager` never holds live state; it drives this registry
/// through the `HierarchyRuntime` seam, and the content host view mounts
/// and unmounts through `TerminalClient`.
///
/// Busy predicates over the catalog (`tabIsDirty`, `worktreeIsDirty`,
/// `isScriptRunning`) live here rather than on the manager because they
/// combine catalog structure with chrome state, and chrome is content
/// runtime state.
@MainActor
@Observable
final class ContentRuntime {
  typealias Factory = @MainActor (ContentSnapshot) -> any TabContent

  @ObservationIgnored private unowned let hierarchy: HierarchyManager
  @ObservationIgnored private let makeContent: Factory
  @ObservationIgnored private let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "content")
  private var contents: [ContentID: any TabContent] = [:]
  /// The slot each Content was last mounted in. A bring-up that knows no
  /// slot (a re-attach after an idle reclaim, an IPC-driven ensure) starts
  /// at this size, so a live session is not resized through another width.
  @ObservationIgnored private var mountedGeometry: [ContentID: ContentGeometry] = [:]

  init(hierarchy: HierarchyManager, makeContent: @escaping Factory) {
    self.hierarchy = hierarchy
    self.makeContent = makeContent
  }

  // Explicit nonisolated deinit; see `TerminalEngine.deinit`.
  deinit {}

  // MARK: - Lifecycle

  /// Create the instance on first use, then bring its live resources up
  /// (or re-attach). Idempotent: an already-live Content returns at once.
  /// Without a `geometry`, the last mounted slot's geometry is used.
  @discardableResult
  func ensure(
    _ snapshot: ContentSnapshot,
    in address: TabAddress,
    worktree: Worktree,
    env: [String: String] = [:],
    geometry: ContentGeometry? = nil
  ) async throws -> any TabContent {
    let content: any TabContent
    if let existing = contents[snapshot.id] {
      content = existing
    } else {
      content = makeContent(snapshot)
      contents[snapshot.id] = content
    }
    try await content.create(
      snapshot: snapshot, at: address, in: worktree, env: env,
      geometry: geometry ?? mountedGeometry[snapshot.id])
    return content
  }

  /// The content host view placed the Content's renderer in a slot of
  /// `geometry` (on appear, and again when the slot changes size).
  func mount(_ id: ContentID, geometry: ContentGeometry) {
    mountedGeometry[id] = geometry
    contents[id]?.mount(geometry: geometry)
  }

  /// The renderer left its slot; the Content stays alive.
  func unmount(_ id: ContentID) {
    contents[id]?.unmount()
  }

  /// Tear the Content down for good and forget it. A Content not brought
  /// up this launch still has a daemon to kill, so it gets an instance
  /// from the catalog snapshot just for the teardown.
  func close(_ id: ContentID) {
    teardownInstance(id)?.close()
  }

  /// Archive teardown; see `TabContent.suspend`. Same lookup as `close`.
  func suspend(_ id: ContentID) {
    teardownInstance(id)?.suspend()
  }

  private func teardownInstance(_ id: ContentID) -> (any TabContent)? {
    mountedGeometry.removeValue(forKey: id)
    if let registered = contents.removeValue(forKey: id) { return registered }
    guard let snapshot = hierarchy.catalog.content(id) else {
      logger.error(
        "teardown of content \(id.raw.uuidString, privacy: .public) that is neither live nor in the catalog")
      return nil
    }
    return makeContent(snapshot)
  }

  func acceptFocus(_ id: ContentID) {
    contents[id]?.acceptFocus()
  }

  // MARK: - Busy signals

  /// OSC 9;4 progress writer. Idempotent; dropped for an unregistered
  /// Content (a surface always registers before it reports).
  func setProgressBusy(_ id: ContentID, _ busy: Bool) {
    guard let chrome = contents[id]?.chrome, chrome.isBusy != busy else { return }
    chrome.isBusy = busy
  }

  /// Foreground-job writer, fed by the engine's poller through the root
  /// reducer. Independent of `setProgressBusy` so the two producers never
  /// clobber each other.
  func setCommandBusy(_ id: ContentID, _ busy: Bool) {
    guard let chrome = contents[id]?.chrome, chrome.isCommandBusy != busy else { return }
    chrome.isCommandBusy = busy
  }

  /// Raw terminal-busy read for one Content (OSC 9;4 progress ∪ running
  /// foreground command).
  func isTerminalBusy(_ id: ContentID) -> Bool {
    contents[id]?.chrome.isTerminalBusy ?? false
  }

  /// True when any registered Content is busy. Fast path for the catalog
  /// walks below: with nothing busy anywhere, the walk is pointless.
  private var anyTerminalBusy: Bool {
    contents.values.contains { $0.chrome.isTerminalBusy }
  }

  /// True when the Tab's Content is busy. Dedicated run-script Contents
  /// are excluded: their activity is expressed by the tab's tinted script
  /// icon and the sidebar ping dot, not the generic spinner (see
  /// `isScriptRunning`).
  func tabIsDirty(_ tabID: TabID) -> Bool {
    guard anyTerminalBusy, let tab = hierarchy.catalog.tab(tabID) else { return false }
    return Self.isDirty(tab, isBusy: isTerminalBusy)
  }

  /// True when any Content inside the Worktree (any Pane, any Tab) is
  /// busy, with the same run-script exclusion as `tabIsDirty`. The sidebar
  /// uses it for the worktree row's busy glyph.
  func worktreeIsDirty(_ worktreeID: WorktreeID) -> Bool {
    guard anyTerminalBusy else { return false }
    for project in hierarchy.catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
      return worktreeIsDirty(worktree)
    }
    return false
  }

  /// Rows already hold the worktree; avoid another catalog search per icon.
  func worktreeIsDirty(_ worktree: Worktree) -> Bool {
    guard anyTerminalBusy else { return false }
    return worktree.allTabs.contains { Self.isDirty($0, isBusy: isTerminalBusy) }
  }

  private static func isDirty(_ tab: Tab, isBusy: (ContentID) -> Bool) -> Bool {
    tab.content.terminal?.runScriptID == nil && isBusy(tab.content.id)
  }

  /// Every script whose tracked run Content in `worktreeID` is executing.
  /// "Stop everything in this worktree" paths iterate this, since they do
  /// not know which scripts are live.
  func runningScriptIDs(in worktreeID: WorktreeID) -> [UUID] {
    guard anyTerminalBusy else { return [] }
    return hierarchy.runScriptContents(in: worktreeID).compactMap { scriptID, contentID in
      isTerminalBusy(contentID) ? scriptID : nil
    }
  }

  /// True when the script's tracked run Content exists AND is running a
  /// foreground command. Drives the toolbar Run⇄Stop toggle; reuses the
  /// tab spinner's busy signal so the two surfaces agree on "executing".
  func isScriptRunning(worktreeID: WorktreeID, scriptID: UUID) -> Bool {
    guard anyTerminalBusy,
      let contentID = hierarchy.runScriptContent(worktreeID: worktreeID, scriptID: scriptID)
    else { return false }
    return isTerminalBusy(contentID)
  }
}
