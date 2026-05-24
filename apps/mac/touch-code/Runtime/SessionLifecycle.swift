import Foundation
import TouchCodeCore
import os.log

/// Quit-time bridge between the live pane runtime and the on-disk
/// `sessions.json` catalog. T2.1 wires this to `NSApplication.willTerminate`
/// so that, immediately before AppKit tears the process down, every active
/// `ZmxClient` is captured into a `SessionCatalog` entry and then issued a
/// `.detach`. The detach closes only the client side of the control socket —
/// the zmx daemon survives, keeping its PTY child alive so the next launch
/// (T2.2) can reattach by socket path.
///
/// Catalog write happens BEFORE any detach: if the app dies mid-shutdown
/// between the two steps, the on-disk record still points at the surviving
/// daemons, which is the worst the next launch needs to recover.
/// Per-quit policy passed to `SessionLifecycle.detachAllForQuit(action:)`. The strategy
/// is decided in `TouchCodeApp` (either from `settings.general.quitStrategy` or via the
/// user's choice in the quit confirmation dialog) so the lifecycle component stays a pure
/// mechanism.
@MainActor
enum QuitAction {
  /// Live tier: persist each daemon's catalog row, then send `.detach` so the daemons
  /// survive the app exit.
  case keepRunning
  /// Snapshot tier: send `.snapshot` to each daemon (writes a `.snap` file and exits) and
  /// reset the on-disk catalog to empty.
  case snapshot
}

@MainActor
final class SessionLifecycle {
  private let manager: HierarchyManager
  private let ghosttyRuntime: GhosttyRuntime?
  private let sessionStore: SessionStore
  private let now: () -> Date
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.lifecycle")

  init(
    manager: HierarchyManager,
    ghosttyRuntime: GhosttyRuntime?,
    sessionStore: SessionStore,
    now: @escaping () -> Date = Date.init
  ) {
    self.manager = manager
    self.ghosttyRuntime = ghosttyRuntime
    self.sessionStore = sessionStore
    self.now = now
  }

  /// Number of live `ZmxClient`s currently held by the runtime's surface registry.
  /// `TouchCodeApp.applicationShouldTerminate` reads this to decide whether to surface the
  /// quit confirmation dialog at all — zero panes means there is nothing to ask about.
  var liveZmxClientCount: Int {
    collectLiveClients().count
  }

  /// Capture every live `ZmxClient`'s daemon metadata into a fresh
  /// `SessionCatalog`, flush it to disk synchronously, then send the requested action on
  /// each client. `action == .keepRunning` sends `.detach` so the daemons survive the
  /// parent process exit; `action == .snapshot` triggers a serialised `.snap` write and
  /// daemon exit.
  ///
  /// Order is load-bearing in the live-tier branch: persist BEFORE detach. A crash between
  /// steps still leaves the next launch with enough information to find the surviving
  /// daemons; a crash before persist leaves nothing, which is no worse than today's
  /// behaviour.
  func detachAllForQuit(action: QuitAction) {
    let liveClients = collectLiveClients()
    if liveClients.isEmpty {
      // Nothing to record — but we still write an empty catalog so the
      // next launch sees a deterministic file (rather than stale entries
      // from a prior run with surviving daemons that have since died).
      persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: [:]))
      return
    }

    switch action {
    case .keepRunning:
      detachLiveTier(liveClients)
    case .snapshot:
      snapshotTier(liveClients)
    }
  }

  /// Discard tier: send `.kill` to every live daemon and reset the on-disk catalog. Used
  /// by the quit confirmation dialog's "Discard" button — the user wants the panes torn
  /// down right now, with no resume on next launch.
  ///
  /// Each `.kill` is run synchronously with the same per-client deadline pattern as
  /// `synchronousSnapshot` so a hung daemon cannot block `applicationShouldTerminate`
  /// indefinitely. A per-client failure / timeout is logged and the loop continues.
  func killAllForQuit() {
    let liveClients = collectLiveClients()
    for client in liveClients {
      synchronousKill(client: client)
    }
    persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: [:]))
  }

  /// Live tier (M2.T2.1): persist each daemon's catalog row, then send
  /// `.Detach` so the daemons survive the app's exit. The next launch
  /// re-`connect(2)`s the recorded sockets in `SessionReaper.sweep`.
  private func detachLiveTier(_ liveClients: [ZmxClient]) {
    let stamp = now()
    var sessions: [String: Session] = [:]
    sessions.reserveCapacity(liveClients.count)
    for client in liveClients {
      let key = client.paneID.raw.uuidString
      sessions[key] = Session(
        paneID: client.paneID,
        socketPath: client.socketPath,
        pid: client.daemonPID,
        createdAt: client.createdAt,
        lastAttachedAt: stamp,
        command: client.command,
        cwd: client.cwd,
        zmxVersion: client.zmxVersion
      )
    }
    persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: sessions))

    for client in liveClients {
      client.detach()
    }
  }

  /// Snapshot tier (M3.T3.2): send `.Snapshot` to each daemon, which
  /// serializes its VT mirror to `<paneID>.snap` and exits. The catalog
  /// is written empty so a previous live-tier quit's rows do not trick
  /// the reaper into probing dead sockets — the only state worth
  /// resurrecting on the next launch lives in the `.snap` files.
  ///
  /// Each `.Snapshot` is run synchronously with a per-client deadline
  /// so a hung daemon cannot block `willTerminate` indefinitely. A
  /// per-client failure is logged and the loop continues — losing one
  /// pane's snapshot is preferable to dropping the rest of them.
  private func snapshotTier(_ liveClients: [ZmxClient]) {
    for client in liveClients {
      do {
        _ = try synchronousSnapshot(client: client)
      } catch {
        logger.error(
          "snapshot failed for pane \(client.paneID, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }
    // Reset the catalog so a prior live-tier write does not survive into
    // the next launch's `SessionReaper.sweep` — the daemons it would
    // reference are now gone. Snapshot-tier resume keys off the `.snap`
    // files instead.
    persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: [:]))
  }

  /// Synchronous bridge to `ZmxClient.snapshot()`. `willTerminate` runs
  /// on the main actor and `ZmxClient.snapshot()` is itself MainActor-
  /// isolated, so we cannot simply block on a `DispatchSemaphore` —
  /// that would deadlock the actor before the daemon's `EOF` callback
  /// can hop back onto it. Instead, kick off the async call inside a
  /// `Task { @MainActor }` and spin `RunLoop.main` in `.default` mode
  /// until either the Task completes (`result.value` becomes non-nil)
  /// or the per-client budget elapses. Spinning the runloop keeps the
  /// MainActor servicing background hops (the read loop's EOF handoff,
  /// the continuation resume) so the snapshot can actually finish.
  private func synchronousSnapshot(client: ZmxClient) throws -> URL {
    let result = SnapshotResult()
    Task { @MainActor in
      do {
        let url = try await client.snapshot()
        result.value = .success(url)
      } catch {
        result.value = .failure(error)
      }
    }
    let deadline = Date().addingTimeInterval(Self.snapshotTimeoutSeconds)
    while result.value == nil && Date() < deadline {
      // Service one batch of pending events on the main runloop. Capped
      // at 50 ms so a stalled snapshot is still bounded by the outer
      // deadline rather than parking inside Foundation indefinitely.
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    switch result.value {
    case .success(let url): return url
    case .failure(let error): throw error
    case .none: throw SnapshotError.timedOut(paneID: client.paneID)
    }
  }

  /// Synchronous bridge to `ZmxClient.kill()`. Mirrors `synchronousSnapshot`'s runloop-
  /// spin pattern so `applicationShouldTerminate` (which runs on the main actor) can
  /// await the daemon's exit without deadlocking the actor that owns the kill callback.
  /// `kill()` itself has an internal 2 s wait for the socket to disappear; we add the
  /// same outer 5 s ceiling used elsewhere so a runaway daemon cannot block quit.
  private func synchronousKill(client: ZmxClient) {
    let done = KillResult()
    Task { @MainActor in
      await client.kill()
      done.finished = true
    }
    let deadline = Date().addingTimeInterval(Self.snapshotTimeoutSeconds)
    while !done.finished && Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !done.finished {
      logger.error("kill timed out for pane \(client.paneID, privacy: .public)")
    }
  }

  /// Reference-shaped one-shot holder for `synchronousKill` — mirrors `SnapshotResult` so
  /// the detached Task's completion is visible to the runloop-spinning waiter without
  /// crossing actor isolation on a captured `var`.
  @MainActor
  private final class KillResult {
    var finished: Bool = false
  }

  /// 5 s per-client budget for the `.Snapshot` round-trip, expressed
  /// as a `TimeInterval` so it composes with the `Date()`-based runloop
  /// spin in `synchronousSnapshot`.
  private static let snapshotTimeoutSeconds: TimeInterval = 5.0

  /// Internal error surfaced when the per-client snapshot budget
  /// elapses without the daemon completing the `.Snapshot` round-trip.
  private enum SnapshotError: Error {
    case timedOut(paneID: PaneID)
  }

  /// Reference-shaped one-shot holder so the Task callback can publish
  /// its outcome to the runloop-spinning waiter without crossing actor
  /// isolation on a captured `var`. MainActor-confined writes + reads.
  @MainActor
  private final class SnapshotResult {
    var value: Result<URL, Error>?
  }

  /// Enumerate every `ZmxClient` whose `PaneSurface` is registered with the
  /// runtime right now. The runtime's surface registry is the only source of
  /// truth for "a daemon is actually attached" — the hierarchy catalog lists
  /// panes whose surfaces have not been built yet (tab activation is lazy),
  /// and walking the catalog at quit time silently dropped those panes,
  /// leaving `sessions.json` empty after most cmd-Q invocations.
  private func collectLiveClients() -> [ZmxClient] {
    guard let runtime = ghosttyRuntime else { return [] }
    return runtime.allLiveSurfaces().map { $0.zmxClient }
  }

  private func persist(catalog: SessionCatalog) {
    do {
      try sessionStore.saveNow(catalog)
    } catch {
      logger.error(
        "Failed to persist sessions.json on quit: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
