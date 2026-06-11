import ComposableArchitecture
import CoreServices
import Foundation
import CodansCore

/// Per-Worktree FSEvents observer on the working-tree root subtree. Fires
/// `events()` whenever a file under `<worktree>` (excluding `.git/`) is
/// created / modified / removed so the sidebar's `+N −M` chip — backed by
/// `git diff HEAD --shortstat` via `WorktreeLocalDiffMonitor` — refreshes
/// after edits made in a pane / editor, not just on commit or row remount.
///
/// Why FSEvents and not `DispatchSource` (which `WorktreeHeadWatcher` uses):
/// HEAD is a single file, so one fd suffices there. A working tree is an
/// arbitrarily deep directory subtree; FSEvents watches it recursively from
/// a single stream and coalesces bursts in the kernel, where a per-file
/// `DispatchSource` would need one fd per file and miss newly-created paths.
///
/// Intrusiveness: FSEvents is a read-only kernel event subscription — it
/// never writes to disk, touches `.git`, or holds locks. The only side
/// effect is the downstream read-only `git diff HEAD --shortstat` the
/// monitor runs when an event lands.
///
/// Design notes:
/// - One `FSEventStream` per watched worktree root, on a shared serial
///   queue. Directory-granularity (no `FileEvents` flag) — every event is
///   treated as a "dirty" signal; the authoritative diff is recomputed by
///   `git`, so we never parse individual paths beyond a `.git/` filter.
/// - Events are debounced (`debounceInterval`) so an editor's atomic save
///   (temp-write → rename, often several raw events) surfaces as one
///   refresh, and a burst of edits collapses to a single trailing fetch.
/// - `.git/` writes (index / logs / `HEAD.lock` → `HEAD`) are filtered out:
///   HEAD-driven refresh is owned by `WorktreeHeadWatcher`, and `git`'s own
///   index churn would otherwise loop us. Queue overflow (`MustScanSubDirs`)
///   needs no special handling — "recompute on any signal" already covers it.
/// - `setWorktrees` is the single mutation entry point — diff against the
///   current set and create / drop streams accordingly. Idempotent on no-op.
@MainActor
final class WorktreeWorkingTreeWatcher {
  private struct Watcher {
    let rootPath: String
    let stream: FSEventStreamRef
    /// Retained for the stream's lifetime; its opaque pointer is handed to
    /// the C callback via `FSEventStreamContext.info`.
    let box: StreamBox
  }

  private var watchers: [WorktreeID: Watcher] = [:]
  private var debounceTasks: [WorktreeID: Task<Void, Never>] = [:]
  private var eventContinuation: AsyncStream<WorktreeID>.Continuation?

  private let debounceInterval: Duration
  private let latency: CFTimeInterval
  private let queue = DispatchQueue(label: "codans.worktree-fswatch")

  init(
    debounceInterval: Duration = .milliseconds(500),
    latency: CFTimeInterval = 0.2
  ) {
    self.debounceInterval = debounceInterval
    self.latency = latency
  }

  /// Single subscriber. Each call replaces the prior stream; the previous
  /// one finishes so the consuming `for await` loop exits. RootFeature's
  /// `onLaunch` is the only caller.
  func events() -> AsyncStream<WorktreeID> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeID.self)
    eventContinuation = continuation
    return stream
  }

  /// Sync the set of watched worktrees against the catalog. Streams for ids
  /// no longer present are torn down; newly-present ids get a stream on
  /// their root path. FSEvents tolerates a not-yet-existing path (it fires
  /// once the path appears) so — unlike `WorktreeHeadWatcher` — no pending /
  /// retry bookkeeping is needed.
  func setWorktrees(_ worktrees: [(id: WorktreeID, path: String)]) {
    let desired = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0.path) })
    let desiredIDs = Set(desired.keys)
    for staleID in Set(watchers.keys).subtracting(desiredIDs) {
      stopWatcher(for: staleID)
    }
    for (id, path) in desired {
      configureWatcher(worktreeID: id, rootPath: path)
    }
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() {
    for id in Array(watchers.keys) { stopWatcher(for: id) }
    eventContinuation?.finish()
    eventContinuation = nil
  }

  private func configureWatcher(worktreeID: WorktreeID, rootPath: String) {
    if let existing = watchers[worktreeID], existing.rootPath == rootPath {
      return
    }
    stopWatcher(for: worktreeID)
    startWatcher(worktreeID: worktreeID, rootPath: rootPath)
  }

  private func startWatcher(worktreeID: WorktreeID, rootPath: String) {
    let box = StreamBox(worktreeID: worktreeID) { [weak self] id in
      // Hops off the FSEvents serial queue back onto the main actor.
      Task { @MainActor in self?.scheduleChanged(worktreeID: id) }
    }
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(box).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagWatchRoot
        | kFSEventStreamCreateFlagIgnoreSelf
    )
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        workingTreeEventCallback,
        &context,
        [rootPath] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags
      )
    else {
      return
    }
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return
    }
    watchers[worktreeID] = Watcher(rootPath: rootPath, stream: stream, box: box)
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

  private func stopWatcher(for worktreeID: WorktreeID) {
    if let watcher = watchers.removeValue(forKey: worktreeID) {
      FSEventStreamStop(watcher.stream)
      FSEventStreamInvalidate(watcher.stream)
      FSEventStreamRelease(watcher.stream)
    }
    debounceTasks.removeValue(forKey: worktreeID)?.cancel()
  }
}

/// Bridges the C `FSEventStreamCallback` (which runs on the stream's
/// dispatch queue and can only carry an opaque `info` pointer) back to the
/// owning watcher. Holds the worktree id and a queue-safe notify closure.
/// `@unchecked Sendable`: it is reached only via an `Unmanaged` pointer and
/// its `notify` closure is itself `@Sendable`.
private final class StreamBox: @unchecked Sendable {
  let worktreeID: WorktreeID
  let notify: @Sendable (WorktreeID) -> Void

  init(worktreeID: WorktreeID, notify: @escaping @Sendable (WorktreeID) -> Void) {
    self.worktreeID = worktreeID
    self.notify = notify
  }
}

/// Non-capturing top-level callback so it converts to a C function pointer.
/// Recovers the `StreamBox` from `info`, drops events that touch only
/// `.git/`, and notifies on any remaining working-tree change.
private let workingTreeEventCallback: FSEventStreamCallback = {
  _, info, numEvents, eventPaths, _, _ in
  guard let info else { return }
  let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
  guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
  for path in paths.prefix(numEvents) {
    if path.contains("/.git/") || path.hasSuffix("/.git") { continue }
    box.notify(box.worktreeID)
    return
  }
}

extension WorktreeWorkingTreeWatcher: DependencyKey {
  /// Unconfigured fallback until `CodansApp.bringUp` overrides it with the
  /// live instance. Mirrors `WorktreeHeadWatcher.liveValue`: a real instance
  /// whose `setWorktrees` is never called, so no streams attach and `events()`
  /// finishes immediately — lets reducer wiring resolve the dependency in
  /// tests without an explicit override.
  static var liveValue: WorktreeWorkingTreeWatcher {
    MainActor.assumeIsolated { WorktreeWorkingTreeWatcher() }
  }

  static var testValue: WorktreeWorkingTreeWatcher { liveValue }
}

extension DependencyValues {
  var worktreeWorkingTreeWatcher: WorktreeWorkingTreeWatcher {
    get { self[WorktreeWorkingTreeWatcher.self] }
    set { self[WorktreeWorkingTreeWatcher.self] = newValue }
  }
}
