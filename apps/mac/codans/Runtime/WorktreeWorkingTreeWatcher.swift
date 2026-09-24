import CodansCore
import ComposableArchitecture
import CoreServices
import Foundation
/// Per-Worktree FSEvents observer on the working-tree root subtree. Fires
/// `events()` whenever a file under `<worktree>` (excluding `.git/`) is
/// created / modified / removed so the sidebar's `+N −M` chip — backed by
/// `WorktreeLocalDiffMonitor` — refreshes
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
/// effect is the downstream read-only git comparison the monitor runs when
/// an event lands.
///
/// Design notes:
/// - One `FSEventStream` per watched worktree root. Directory-granularity
///   (no `FileEvents` flag) — every event is treated as a "dirty" signal;
///   the authoritative diff is recomputed by `git`, so we never parse
///   individual paths beyond a `.git/` filter.
/// - Events are debounced (`debounceInterval`) so an editor's atomic save
///   (temp-write → rename, often several raw events) surfaces as one
///   refresh, and a burst of edits collapses to a single trailing fetch.
/// - `.git/` writes (index / logs / `HEAD.lock` → `HEAD`) are filtered out:
///   HEAD-driven refresh is owned by `WorktreeHeadWatcher`, and `git`'s own
///   index churn would otherwise loop us. Queue overflow (`MustScanSubDirs`)
///   needs no special handling — "recompute on any signal" already covers it.
/// - `setWorktrees` is the single mutation entry point — diff against the
///   current set and create / drop streams accordingly. Idempotent on no-op.
/// - Registration is asynchronous: `FSEventStreamStart` performs a
///   synchronous RPC against fseventsd that can block for seconds per
///   stream on a busy system (measured: 17 sequential starts ≈ 39 s), so
///   create/start/stop run off the main actor on dedicated queues and the
///   main actor only mutates `entries` (see `beginWatching`).
@MainActor
final class WorktreeWorkingTreeWatcher {
  private var entries: [WorktreeID: Entry] = [:]
  /// Distinguishes two starts of the *same* path (A → B → A): a completion
  /// only installs its stream when the entry it finds is still the starting
  /// claim it was dispatched under. Paths alone cannot tell those apart.
  private var nextGeneration: UInt64 = 0
  private var debounceTasks: [WorktreeID: Task<Void, Never>] = [:]
  /// Test observability: how many registered streams have been discarded
  /// (torn down without staying installed). The re-point test asserts the
  /// superseded start is discarded exactly once.
  private(set) var discardedStreamCount = 0
  private var eventContinuation: AsyncStream<WorktreeID>.Continuation?

  private let debounceInterval: Duration
  private let latency: CFTimeInterval
  /// Delivers stream events and nothing else, so a multi-second registration
  /// on `registerQueue` can never head-of-line-block delivery or teardown.
  private let queue = DispatchQueue(label: "codans.worktree-fswatch")
  /// Runs `FSEventStreamCreate` / `Start` and every teardown — the calls
  /// that round-trip to fseventsd and may block.
  private let registerQueue = DispatchQueue(label: "codans.worktree-fswatch.register")
  /// Seam for tests: the blocking half of registration, so a test can hold
  /// a start open and prove `setWorktrees` returned without it.
  private let streamStarter: @Sendable (FSEventStreamRef) -> Bool

  init(
    debounceInterval: Duration = .milliseconds(500),
    latency: CFTimeInterval = 0.2,
    streamStarter: @escaping @Sendable (FSEventStreamRef) -> Bool = {
      FSEventStreamStart($0)
    }
  ) {
    self.debounceInterval = debounceInterval
    self.latency = latency
    self.streamStarter = streamStarter
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
    // `entries` is the single authority: stale cleanup must also cover ids
    // whose start is still in flight, or a worktree removed mid-registration
    // would install its stream after removal and leak it.
    for staleID in Set(entries.keys).subtracting(desiredIDs) {
      retire(staleID)
    }
    for (id, path) in desired {
      configureWatcher(worktreeID: id, rootPath: path)
    }
  }

  /// Test observability for the asynchronous install path: true once a
  /// stream for exactly this (id, path) is running. Event delivery can't be
  /// asserted in-process (`IgnoreSelf` suppresses our own writes, and CI
  /// fseventsd latency varies), so the suite pins install state instead.
  func isWatching(_ worktreeID: WorktreeID, path: String) -> Bool {
    if case .running(let watcher) = entries[worktreeID] {
      return watcher.rootPath == path
    }
    return false
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() {
    for id in Array(entries.keys) { retire(id) }
    eventContinuation?.finish()
    eventContinuation = nil
  }

  private func configureWatcher(worktreeID: WorktreeID, rootPath: String) {
    switch entries[worktreeID] {
    case .running(let watcher) where watcher.rootPath == rootPath:
      return
    case .starting(let path, _) where path == rootPath:
      return
    default:
      break
    }
    retire(worktreeID)
    beginWatching(
      worktreeID: worktreeID, rootPath: rootPath, generation: nextGeneration
    )
    nextGeneration += 1
  }

  /// Registers a stream **off the main actor**.
  ///
  /// `FSEventStreamStart` performs a synchronous registration RPC against
  /// fseventsd (`register_with_server` → `f2d_register_rpc`). On a machine
  /// where fseventsd is busy — measured locally with 16 agents churning
  /// worktrees: 17 sequential starts took ~39 s, single calls up to 7.7 s —
  /// that RPC blocks. Called from the old MainActor path it froze the whole
  /// UI for the duration, which was the entire "relaunch takes a minute"
  /// window after the editor-icon fix landed (sampled: main thread parked in
  /// `FSEventStreamStart` for ~50 s post-launch). Event delivery was already
  /// bound to `queue`; create/start/stop run on `registerQueue` so the main
  /// actor only ever touches `entries`.
  private func beginWatching(
    worktreeID: WorktreeID, rootPath: String, generation: UInt64
  ) {
    entries[worktreeID] = .starting(path: rootPath, generation: generation)
    let box = StreamBox(worktreeID: worktreeID) { [weak self] box in
      // Hops off the FSEvents delivery queue back onto the main actor,
      // carrying the box so `scheduleChanged` can drop events from a
      // stream that no longer owns this worktree's entry.
      Task { @MainActor in self?.scheduleChanged(worktreeID: worktreeID, box: box) }
    }
    let deliveryQueue = queue
    let registerQueue = self.registerQueue
    let streamLatency = latency
    let starter = streamStarter
    registerQueue.async { [weak self] in
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(box).toOpaque(),
        // The stream owns a reference to the box: FSEvents calls `retain`
        // when it copies the context and `release` when the stream is
        // invalidated, so an in-flight callback can never race the box's
        // deallocation regardless of which queue teardown runs on.
        retain: { info in
          UnsafeRawPointer(Unmanaged<StreamBox>.fromOpaque(info!).retain().toOpaque())
        },
        release: { info in
          Unmanaged<StreamBox>.fromOpaque(info!).release()
        },
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
          {
            _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
            guard
              let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String]
            else { return }
            for path in paths.prefix(numEvents) {
              if path.contains("/.git/") || path.hasSuffix("/.git") { continue }
              box.notify(box)
              return
            }
          },
          &context,
          [rootPath] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          streamLatency,
          flags
        )
      else {
        Task { @MainActor in
          self?.registrationFailed(worktreeID: worktreeID, generation: generation)
        }
        return
      }
      FSEventStreamSetDispatchQueue(stream, deliveryQueue)
      guard starter(stream) else {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Task { @MainActor in
          self?.registrationFailed(worktreeID: worktreeID, generation: generation)
        }
        return
      }
      let watcher = Watcher(rootPath: rootPath, stream: stream, box: box)
      Task { @MainActor [weak self] in
        guard let self else {
          // The watcher died mid-start; nobody would ever stop this stream.
          registerQueue.async {
            tearDownFSEventStream(watcher.stream)
          }
          return
        }
        self.install(watcher, for: worktreeID, generation: generation)
      }
    }
  }

  /// Installs a stream registered on `registerQueue`, or tears it straight
  /// back down if its claim was superseded (or retired) while the
  /// registration RPC was in flight.
  private func install(_ watcher: Watcher, for worktreeID: WorktreeID, generation: UInt64) {
    guard
      case .starting(let path, let gen) = entries[worktreeID],
      path == watcher.rootPath,
      gen == generation
    else {
      discard(watcher)
      return
    }
    entries[worktreeID] = .running(watcher)
  }

  /// Clears a failed start's claim only when that claim is still its own —
  /// a start for an older path must not delete a newer path's claim.
  private func registrationFailed(worktreeID: WorktreeID, generation: UInt64) {
    guard case .starting(_, let gen) = entries[worktreeID], gen == generation else {
      return
    }
    entries.removeValue(forKey: worktreeID)
  }

  private func scheduleChanged(worktreeID: WorktreeID, box: StreamBox) {
    // A retired stream keeps delivering until its teardown (queued behind
    // registrations) actually runs; events from any box that no longer owns
    // the entry are dropped here instead of resurrecting the debounce.
    guard case .running(let watcher) = entries[worktreeID], watcher.box === box else {
      return
    }
    debounceTasks[worktreeID]?.cancel()
    let interval = debounceInterval
    debounceTasks[worktreeID] = Task { [weak self, weak box] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, let box else { return }
        // Re-check after the debounce sleep: the entry may have been
        // retired or re-pointed while we slept.
        guard case .running(let watcher) = self.entries[worktreeID],
          watcher.box === box
        else { return }
        self.debounceTasks.removeValue(forKey: worktreeID)
        self.eventContinuation?.yield(worktreeID)
      }
    }
  }

  /// Removes the id's claim — an in-flight start completes into a mismatched
  /// entry and tears itself down — and schedules teardown for a running one.
  private func retire(_ worktreeID: WorktreeID) {
    switch entries.removeValue(forKey: worktreeID) {
    case .starting:
      break
    case .running(let watcher):
      discard(watcher)
    case nil:
      break
    }
    debounceTasks.removeValue(forKey: worktreeID)?.cancel()
  }

  /// Stop / invalidate / release must run as a trio, in order, off the
  /// main actor (`Invalidate` can talk to fseventsd just like `Start` did),
  /// on `registerQueue` alongside every other stream-lifecycle call. The
  /// box's lifetime is stream-owned via the context retain/release
  /// callbacks, so no `withExtendedLifetime` dance is needed against an
  /// in-flight callback on the delivery queue.
  private func discard(_ watcher: Watcher) {
    discardedStreamCount += 1
    registerQueue.async {
      tearDownFSEventStream(watcher.stream)
    }
  }
}

/// Stop / invalidate / release must run as a trio, in order, off the main
/// actor (`Invalidate` can talk to fseventsd just like `Start` did).
private nonisolated func tearDownFSEventStream(_ stream: FSEventStreamRef) {
  FSEventStreamStop(stream)
  FSEventStreamInvalidate(stream)
  FSEventStreamRelease(stream)
}

/// Authoritative per-worktree state. `.starting` is the claim a registration
/// in flight on `registerQueue` must still find when it completes; the
/// generation tells apart two starts of the same path (A → B → A).
private enum Entry {
  case starting(path: String, generation: UInt64)
  case running(Watcher)
}

private nonisolated struct Watcher: @unchecked Sendable {
  let rootPath: String
  let stream: FSEventStreamRef
  /// Retained for the stream's lifetime; its opaque pointer is handed to
  /// the C callback via `FSEventStreamContext.info`.
  let box: StreamBox
}

/// Bridges the C `FSEventStreamCallback` (which runs on the stream's
/// dispatch queue and can only carry an opaque `info` pointer) back to the
/// owning watcher. Holds the worktree id and a queue-safe notify closure.
/// `@unchecked Sendable`: it is reached only via an `Unmanaged` pointer and
/// its `notify` closure is itself `@Sendable`.
private final class StreamBox: @unchecked Sendable {
  let worktreeID: WorktreeID
  /// Receives the box itself so the main-actor hop can verify the sender
  /// still owns the worktree's entry.
  let notify: @Sendable (StreamBox) -> Void

  init(worktreeID: WorktreeID, notify: @escaping @Sendable (StreamBox) -> Void) {
    self.worktreeID = worktreeID
    self.notify = notify
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
