import CoreServices
import Foundation
/// Keyed FSEvents observer on a set of directory subtrees. Each key owns one
/// stream on one root path; `events()` yields the key whenever an accepted
/// path under its root changes. `WorktreeWorkingTreeWatcher` and
/// `RemoteRefsWatcher` are thin configurations of it.
///
/// Why FSEvents and not `DispatchSource` (which `WorktreeHeadWatcher` uses):
/// a subtree is arbitrarily deep; FSEvents watches it recursively from a
/// single stream and coalesces bursts in the kernel, where a per-file
/// `DispatchSource` would need one fd per file and miss newly-created paths.
///
/// Intrusiveness: FSEvents is a read-only kernel event subscription — it
/// never writes to disk, touches `.git`, or holds locks.
///
/// Design notes:
/// - One `FSEventStream` per key. Every accepted event is a "dirty" signal;
///   consumers recompute from the source of truth, so paths are only
///   filtered, never parsed further. `fileEvents` asks for per-file paths
///   when the filter needs to tell files in one directory apart.
/// - Events are debounced (`debounceInterval`) per key so a burst (an atomic
///   save, a `.lock` → rename) surfaces as one yield. Queue overflow
///   (`MustScanSubDirs`) needs no special handling for the same reason.
/// - `setRoots` is the single mutation entry point — diff against the
///   current set and create / drop streams accordingly. Idempotent on no-op.
/// - Registration is asynchronous: `FSEventStreamStart` performs a
///   synchronous RPC against fseventsd that can block for seconds per
///   stream on a busy system (measured: 17 sequential starts ≈ 39 s), so
///   create/start/stop run off the main actor on dedicated queues and the
///   main actor only mutates `entries` (see `beginWatching`).
@MainActor
final class FSEventsTreeWatcher<Key: Hashable & Sendable> {
  private var entries: [Key: Entry] = [:]
  /// Distinguishes two starts of the *same* path (A → B → A): a completion
  /// only installs its stream when the entry it finds is still the starting
  /// claim it was dispatched under. Paths alone cannot tell those apart.
  private var nextGeneration: UInt64 = 0
  private var debounceTasks: [Key: Task<Void, Never>] = [:]
  /// Test observability: how many registered streams have been discarded
  /// (torn down without staying installed). The re-point test asserts the
  /// superseded start is discarded exactly once.
  private(set) var discardedStreamCount = 0
  private var eventContinuation: AsyncStream<Key>.Continuation?

  private let debounceInterval: Duration
  private let latency: CFTimeInterval
  private let fileEvents: Bool
  /// Decides whether an event path counts as a change. Runs on the delivery
  /// queue, so it must be cheap and `@Sendable`.
  private let accepts: @Sendable (String) -> Bool
  /// Delivers stream events and nothing else, so a multi-second registration
  /// on `registerQueue` can never head-of-line-block delivery or teardown.
  private let queue: DispatchQueue
  /// Runs `FSEventStreamCreate` / `Start` and every teardown — the calls
  /// that round-trip to fseventsd and may block.
  private let registerQueue: DispatchQueue
  /// Seam for tests: the blocking half of registration, so a test can hold
  /// a start open and prove `setRoots` returned without it.
  private let streamStarter: @Sendable (FSEventStreamRef) -> Bool

  init(
    label: String,
    debounceInterval: Duration,
    latency: CFTimeInterval = 0.2,
    fileEvents: Bool = false,
    accepts: @escaping @Sendable (String) -> Bool,
    streamStarter: @escaping @Sendable (FSEventStreamRef) -> Bool = {
      FSEventStreamStart($0)
    }
  ) {
    self.debounceInterval = debounceInterval
    self.latency = latency
    self.fileEvents = fileEvents
    self.accepts = accepts
    self.queue = DispatchQueue(label: label)
    self.registerQueue = DispatchQueue(label: "\(label).register")
    self.streamStarter = streamStarter
  }

  // Swift 6.2 (Xcode 26.0) crashes in IRGen on the synthesized deinit of
  // this generic main-actor class. An explicit deinit avoids that path.
  deinit {}

  /// Single subscriber. Each call replaces the prior stream; the previous
  /// one finishes so the consuming `for await` loop exits.
  func events() -> AsyncStream<Key> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: Key.self)
    eventContinuation = continuation
    return stream
  }

  /// Sync the watched set. Streams for keys no longer present are torn
  /// down; newly-present keys get a stream on their root path. FSEvents
  /// tolerates a not-yet-existing path (it fires once the path appears), so
  /// no pending / retry bookkeeping is needed.
  func setRoots(_ roots: [Key: String]) {
    // `entries` is the single authority: stale cleanup must also cover keys
    // whose start is still in flight, or a key removed mid-registration
    // would install its stream after removal and leak it.
    for staleKey in Set(entries.keys).subtracting(roots.keys) {
      retire(staleKey)
    }
    for (key, path) in roots {
      configureWatcher(key: key, rootPath: path)
    }
  }

  /// Test observability for the asynchronous install path: true once a
  /// stream for exactly this (id, path) is running. Event delivery can't be
  /// asserted in-process (`IgnoreSelf` suppresses our own writes, and CI
  /// fseventsd latency varies), so the suite pins install state instead.
  func isWatching(_ key: Key, path: String) -> Bool {
    if case .running(let watcher) = entries[key] {
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

  private func configureWatcher(key: Key, rootPath: String) {
    switch entries[key] {
    case .running(let watcher) where watcher.rootPath == rootPath:
      return
    case .starting(let path, _) where path == rootPath:
      return
    default:
      break
    }
    retire(key)
    beginWatching(
      key: key, rootPath: rootPath, generation: nextGeneration
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
    key: Key, rootPath: String, generation: UInt64
  ) {
    entries[key] = .starting(path: rootPath, generation: generation)
    let box = StreamBox(accepts: accepts) { [weak self] box in
      // Hops off the FSEvents delivery queue back onto the main actor,
      // carrying the box so `scheduleChanged` can drop events from a
      // stream that no longer owns this key's entry.
      Task { @MainActor in self?.scheduleChanged(key: key, box: box) }
    }
    let deliveryQueue = queue
    let registerQueue = self.registerQueue
    let streamLatency = latency
    let starter = streamStarter
    let fileEvents = self.fileEvents
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
      var flags = UInt32(
        kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
          | kFSEventStreamCreateFlagIgnoreSelf
      )
      if fileEvents { flags |= UInt32(kFSEventStreamCreateFlagFileEvents) }
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
            for path in paths.prefix(numEvents) where box.accepts(path) {
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
          self?.registrationFailed(key: key, generation: generation)
        }
        return
      }
      FSEventStreamSetDispatchQueue(stream, deliveryQueue)
      guard starter(stream) else {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Task { @MainActor in
          self?.registrationFailed(key: key, generation: generation)
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
        self.install(watcher, for: key, generation: generation)
      }
    }
  }

  /// Installs a stream registered on `registerQueue`, or tears it straight
  /// back down if its claim was superseded (or retired) while the
  /// registration RPC was in flight.
  private func install(_ watcher: Watcher, for key: Key, generation: UInt64) {
    guard
      case .starting(let path, let gen) = entries[key],
      path == watcher.rootPath,
      gen == generation
    else {
      discard(watcher)
      return
    }
    entries[key] = .running(watcher)
  }

  /// Clears a failed start's claim only when that claim is still its own —
  /// a start for an older path must not delete a newer path's claim.
  private func registrationFailed(key: Key, generation: UInt64) {
    guard case .starting(_, let gen) = entries[key], gen == generation else {
      return
    }
    entries.removeValue(forKey: key)
  }

  private func scheduleChanged(key: Key, box: StreamBox) {
    // A retired stream keeps delivering until its teardown (queued behind
    // registrations) actually runs; events from any box that no longer owns
    // the entry are dropped here instead of resurrecting the debounce.
    guard case .running(let watcher) = entries[key], watcher.box === box else {
      return
    }
    debounceTasks[key]?.cancel()
    let interval = debounceInterval
    debounceTasks[key] = Task { [weak self, weak box] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, let box else { return }
        // Re-check after the debounce sleep: the entry may have been
        // retired or re-pointed while we slept.
        guard case .running(let watcher) = self.entries[key],
          watcher.box === box
        else { return }
        self.debounceTasks.removeValue(forKey: key)
        self.eventContinuation?.yield(key)
      }
    }
  }

  /// Removes the id's claim — an in-flight start completes into a mismatched
  /// entry and tears itself down — and schedules teardown for a running one.
  private func retire(_ key: Key) {
    switch entries.removeValue(forKey: key) {
    case .starting:
      break
    case .running(let watcher):
      discard(watcher)
    case nil:
      break
    }
    debounceTasks.removeValue(forKey: key)?.cancel()
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

/// Authoritative per-key state. `.starting` is the claim a registration
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
/// owning watcher. Holds the path filter and a queue-safe notify closure;
/// not generic, because the C callback cannot capture a generic parameter.
/// `@unchecked Sendable`: it is reached only via an `Unmanaged` pointer and
/// both closures are themselves `@Sendable`.
private final class StreamBox: @unchecked Sendable {
  let accepts: @Sendable (String) -> Bool
  /// Receives the box itself so the main-actor hop can verify the sender
  /// still owns the key's entry.
  let notify: @Sendable (StreamBox) -> Void

  init(
    accepts: @escaping @Sendable (String) -> Bool,
    notify: @escaping @Sendable (StreamBox) -> Void
  ) {
    self.accepts = accepts
    self.notify = notify
  }
}
