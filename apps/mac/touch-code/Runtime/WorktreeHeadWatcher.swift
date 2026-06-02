import ComposableArchitecture
import Darwin
import Dispatch
import Foundation
import TouchCodeCore

/// Per-Worktree file-system observer on a worktree's HEAD-related files:
/// the `HEAD` symref and its reflog (`logs/HEAD`). Fires `events()` whenever
/// HEAD *moves* so the rest of the app can refresh the catalog row's
/// `branch`, the WorktreeHeader, the `+N −M` diff-stat chip, and any
/// per-branch derived state (PR badge, GitHub fetch).
///
/// Why two files — they fire on disjoint operations:
/// - **`HEAD`** content flips only on a *branch switch* (`git checkout` /
///   `git switch`). Closes the canonical HAN-62 gap: a terminal-driven
///   checkout inside a pane doesn't fire NSApplication's `didBecomeActive`.
/// - **`logs/HEAD`** (the reflog) appends a line on *every* HEAD movement —
///   `commit` / `reset` / `merge` / `rebase` / `pull` — none of which
///   rewrite `HEAD`. Without it a `git commit` leaves the diff-stat chip
///   stale: `HEAD`'s content is unchanged and the working-tree watcher
///   filters out `.git/`, so nothing else would re-run `git diff HEAD`.
///   The reflog also lives in the worktree's gitdir (outside the worktree
///   root), so the working-tree FSEvents watcher can't see it regardless.
///
/// Design notes:
/// - One `DispatchSource.makeFileSystemObjectSource(O_EVTONLY)` per watched
///   file. Branch flips / commits land within tens of milliseconds.
/// - Events are debounced (~200ms) *per worktree* so a single operation
///   (which may touch HEAD and the reflog, or append several reflog lines)
///   surfaces as one event, not several. HEAD and reflog coalesce together.
/// - `HEAD` writes are typically atomic renames (`HEAD.lock` → `HEAD`),
///   which fire `.delete` / `.rename` on the original fd. The reflog is
///   normally appended in place (`.write` / `.extend`, fd stays valid) and
///   is only renamed/deleted by `git gc` / `reflog expire`. Either way a
///   `.delete` / `.rename` schedules a short restart to re-attach to the
///   fresh inode without leaking the stale source, and still emits.
/// - `setWorktrees` is the single mutation entry point — diff against the
///   current set and create / drop watchers accordingly. Idempotent on
///   no-op calls.
@MainActor
final class WorktreeHeadWatcher {
  /// The two HEAD-related files watched per worktree. Both mean "HEAD
  /// moved"; they fire on disjoint git operations (see the type doc).
  private enum Kind: Hashable, Sendable, CaseIterable {
    case head
    case reflog
  }

  /// Identifies one watched file: a `(worktree, kind)` pair. The transient
  /// maps key on this so a HEAD source and a reflog source for the same
  /// worktree don't clobber each other's restart / pending state.
  private struct Key: Hashable {
    let worktreeID: WorktreeID
    let kind: Kind
  }

  private struct Source {
    let fileURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private var sources: [Key: Source] = [:]
  /// Files whose path couldn't be resolved / opened yet (folder not a repo
  /// yet, reflog not written yet, HEAD mid-rename). Re-tried on `setWorktrees`
  /// or the scheduled restart. Stores the worktree URL to re-resolve from.
  private var pending: [Key: URL] = [:]
  /// Debounce keyed by worktree, not file, so HEAD + reflog events for one
  /// operation collapse into a single yield.
  private var debounceTasks: [WorktreeID: Task<Void, Never>] = [:]
  private var restartTasks: [Key: Task<Void, Never>] = [:]
  private var eventContinuation: AsyncStream<WorktreeID>.Continuation?

  private let debounceInterval: Duration
  private let restartDelay: Duration

  init(
    debounceInterval: Duration = .milliseconds(200),
    restartDelay: Duration = .milliseconds(500)
  ) {
    self.debounceInterval = debounceInterval
    self.restartDelay = restartDelay
  }

  /// Single subscriber. Each call replaces the prior stream; the
  /// previous one finishes so the consuming `for await` loop exits.
  /// RootFeature's `onLaunch` is the only caller.
  func events() -> AsyncStream<WorktreeID> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeID.self)
    eventContinuation = continuation
    return stream
  }

  /// Sync the set of watched worktrees against the catalog. Watchers
  /// for ids no longer present are torn down; newly-present ids get a
  /// watcher attached for each HEAD-related file that can be resolved
  /// (folders that aren't git repos yet are remembered in `pending`
  /// and re-tried on the next `setWorktrees` call once the path
  /// becomes a repo).
  func setWorktrees(_ worktrees: [(id: WorktreeID, path: String)]) {
    let desired = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, URL(fileURLWithPath: $0.path)) })
    let desiredIDs = Set(desired.keys)
    let currentIDs = Set(sources.keys.map(\.worktreeID))
      .union(pending.keys.map(\.worktreeID))
    for staleID in currentIDs.subtracting(desiredIDs) {
      stopWatcher(for: staleID)
    }
    for (id, url) in desired {
      configureWatcher(worktreeID: id, worktreeURL: url)
    }
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() {
    for id in Set(sources.keys.map(\.worktreeID)).union(pending.keys.map(\.worktreeID)) {
      stopWatcher(for: id)
    }
    eventContinuation?.finish()
    eventContinuation = nil
  }

  private func configureWatcher(worktreeID: WorktreeID, worktreeURL: URL) {
    for kind in Kind.allCases {
      configureSource(key: Key(worktreeID: worktreeID, kind: kind), worktreeURL: worktreeURL)
    }
  }

  private func configureSource(key: Key, worktreeURL: URL) {
    guard let fileURL = Self.fileURL(kind: key.kind, worktreeURL: worktreeURL) else {
      // Not a git repo yet (e.g. `addProject(gitRoot: nil)` placeholder).
      // Remember it so the next `setWorktrees` retry picks it up after
      // `git init` lands.
      pending[key] = worktreeURL
      stopSource(key)
      return
    }
    if let existing = sources[key], existing.fileURL == fileURL {
      return
    }
    stopSource(key)
    pending.removeValue(forKey: key)
    startSource(key: key, worktreeURL: worktreeURL, fileURL: fileURL)
  }

  private func startSource(key: Key, worktreeURL: URL, fileURL: URL) {
    let path = fileURL.path(percentEncoded: false)
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      // File not present yet: the reflog isn't written until the first ref
      // update, and HEAD can vanish mid-rename between resolve and open.
      // Queue a restart so the next ~500ms re-resolve catches it.
      pending[key] = worktreeURL
      scheduleRestart(key: key)
      return
    }
    let queue = DispatchQueue(
      label: "touch-code.head-watcher.\(key.worktreeID.raw.uuidString).\(key.kind)"
    )
    // HEAD flips via atomic rename; the reflog grows via in-place append.
    // Include `.extend` for the reflog so a pure size-growth append still
    // wakes the source.
    let eventMask: DispatchSource.FileSystemEvent =
      key.kind == .head
      ? [.write, .rename, .delete, .attrib]
      : [.write, .extend, .rename, .delete]
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: eventMask,
      queue: queue
    )
    source.setEventHandler { @Sendable [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleEvent(key: key, worktreeURL: worktreeURL, event: event)
      }
    }
    source.setCancelHandler { @Sendable in
      close(fd)
    }
    source.resume()
    sources[key] = Source(fileURL: fileURL, source: source)
  }

  private func handleEvent(
    key: Key,
    worktreeURL: URL,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      // HEAD: atomic `HEAD.lock` → `HEAD` rename. Reflog: `git gc` /
      // `reflog expire` rewrite. Either invalidates our fd — drop the
      // current source, remember the worktree for the next reattach, and
      // still emit a debounced event (the fresh file already holds the
      // post-op state).
      stopSource(key)
      pending[key] = worktreeURL
      scheduleRestart(key: key)
      scheduleChanged(worktreeID: key.worktreeID)
      return
    }
    scheduleChanged(worktreeID: key.worktreeID)
  }

  private func scheduleChanged(worktreeID: WorktreeID) {
    debounceTasks[worktreeID]?.cancel()
    let interval = debounceInterval
    debounceTasks[worktreeID] = Task { [weak self] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.debounceTasks.removeValue(forKey: worktreeID)
        self.eventContinuation?.yield(worktreeID)
      }
    }
  }

  private func scheduleRestart(key: Key) {
    restartTasks[key]?.cancel()
    let delay = restartDelay
    restartTasks[key] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.restartTasks.removeValue(forKey: key)
        guard let worktreeURL = self.pending[key] else { return }
        self.configureSource(key: key, worktreeURL: worktreeURL)
      }
    }
  }

  private func stopSource(_ key: Key) {
    if let watcher = sources.removeValue(forKey: key) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: WorktreeID) {
    for kind in Kind.allCases {
      let key = Key(worktreeID: worktreeID, kind: kind)
      stopSource(key)
      pending.removeValue(forKey: key)
      restartTasks.removeValue(forKey: key)?.cancel()
    }
    debounceTasks.removeValue(forKey: worktreeID)?.cancel()
  }

  /// Resolve the on-disk path of one HEAD-related file for a worktree.
  /// The reflog is a fixed sibling of `HEAD` inside the same gitdir, so it
  /// rides on `WorktreeHeadResolver`'s main-checkout / linked-worktree
  /// layout handling. Returns `nil` when the worktree isn't a git repo.
  private static func fileURL(kind: Kind, worktreeURL: URL) -> URL? {
    guard let headURL = WorktreeHeadResolver.headURL(for: worktreeURL) else {
      return nil
    }
    switch kind {
    case .head:
      return headURL
    case .reflog:
      return headURL.deletingLastPathComponent().appending(path: "logs/HEAD")
    }
  }
}

extension WorktreeHeadWatcher: DependencyKey {
  /// Unconfigured fallback used until `TouchCodeApp.bringUp` overrides it
  /// with the live instance. Mirrors `ProjectReconciler.liveValue`: a real
  /// instance, but `setWorktrees` is never called so no watchers are
  /// attached and `events()` finishes immediately. Lets reducer wiring
  /// resolve `@Dependency(WorktreeHeadWatcher.self)` in tests without an
  /// explicit override.
  static var liveValue: WorktreeHeadWatcher {
    MainActor.assumeIsolated { WorktreeHeadWatcher() }
  }

  static var testValue: WorktreeHeadWatcher { liveValue }
}

extension DependencyValues {
  var worktreeHeadWatcher: WorktreeHeadWatcher {
    get { self[WorktreeHeadWatcher.self] }
    set { self[WorktreeHeadWatcher.self] = newValue }
  }
}
