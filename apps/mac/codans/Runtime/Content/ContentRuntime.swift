import CodansCore
import Foundation
import Observation

/// Registry of live Content, keyed by `ContentID`. Owns the `TabContent`
/// instances — creates one the first time a Content is brought up, drops
/// it on close / suspend — and is where views fetch a renderer and the
/// strip fetches a `TabChrome`. `HierarchyManager` never holds live
/// state; it drives this registry through the `HierarchyRuntime` seam.
///
/// Busy predicates over the catalog (`tabIsDirty`, `worktreeIsDirty`,
/// `isScriptRunning`) live here rather than on the manager because they
/// combine catalog structure with chrome state, and chrome is content
/// runtime state.
@MainActor
@Observable
final class ContentRuntime {
  typealias Factory = @MainActor (ContentSnapshot) -> any TabContent

  /// Whether this launch may run the session reaper, the filesystem
  /// orphan sweep and the unread sweep. Off when the catalog loaded with
  /// losses or read-only: a dropped Tab's session must not be reaped as
  /// an orphan, and a catalog this build cannot write must not have its
  /// sessions touched.
  let sessionSweepsEnabled: Bool

  @ObservationIgnored private unowned let hierarchy: HierarchyManager
  @ObservationIgnored private let makeContent: Factory
  private var contents: [ContentID: any TabContent] = [:]

  init(
    hierarchy: HierarchyManager,
    loadReport: CatalogLoadReport = .clean,
    makeContent: @escaping Factory
  ) {
    self.hierarchy = hierarchy
    self.sessionSweepsEnabled = loadReport.allowsSessionSweeps
    self.makeContent = makeContent
  }

  // Explicit nonisolated deinit; see `TerminalEngine.deinit`.
  deinit {}

  // MARK: - Registry

  func content(for id: ContentID) -> (any TabContent)? {
    contents[id]
  }

  func chrome(for id: ContentID) -> TabChrome? {
    contents[id]?.chrome
  }

  var registeredContentIDs: Set<ContentID> {
    Set(contents.keys)
  }

  /// Registered Contents whose live resources exist right now.
  var liveContentIDs: Set<ContentID> {
    Set(contents.filter { $0.value.isLive }.keys)
  }

  /// Create the instance on first use, then bring its live resources up
  /// (or re-attach). Idempotent: an already-live Content returns at once.
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
    try await content.create(snapshot: snapshot, at: address, in: worktree, env: env, geometry: geometry)
    return content
  }

  func mount(_ id: ContentID, geometry: ContentGeometry) {
    contents[id]?.mount(geometry: geometry)
  }

  func unmount(_ id: ContentID) {
    contents[id]?.unmount()
  }

  /// Tear the Content down for good and forget it. A Content that was
  /// never brought up this launch has no instance here; the caller's
  /// engine-side close still kills its daemon.
  func close(_ id: ContentID) {
    contents.removeValue(forKey: id)?.close()
  }

  /// Archive teardown; see `TabContent.suspend`.
  func suspend(_ id: ContentID) {
    contents.removeValue(forKey: id)?.suspend()
  }

  /// Forget the instance without touching its resources — the engine
  /// already reported the surface gone.
  func release(_ id: ContentID) {
    contents.removeValue(forKey: id)
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
