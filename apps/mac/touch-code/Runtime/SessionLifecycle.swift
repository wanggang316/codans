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
///
/// `detachAllForQuit(action:)` takes a `TouchCodeCore.QuitAction` — the canonical
/// declaration lives in `TouchCodeCore` so the UI and the runtime share one definition.
/// `TouchCodeApp` decides which action to pass (from `settings.general.quitAction` or
/// the user's dialog choice) so the lifecycle component stays a pure mechanism.

@MainActor
final class SessionLifecycle {
  private let manager: HierarchyManager
  private let ghosttyRuntime: GhosttyRuntime?
  private let coordinator: SessionCoordinator
  private let now: () -> Date
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.lifecycle")
  /// Optional agent-state source for quit-time snapshot. Set by AppState
  /// once the registry is built. Nil branch keeps tests and headless
  /// callers from needing to wire either of the two new dependencies.
  var agentSnapshotProvider: (@MainActor () -> [PersistedAgentRecord])?

  init(
    manager: HierarchyManager,
    ghosttyRuntime: GhosttyRuntime?,
    coordinator: SessionCoordinator,
    now: @escaping () -> Date = Date.init
  ) {
    self.manager = manager
    self.ghosttyRuntime = ghosttyRuntime
    self.coordinator = coordinator
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

  /// Live tier (M2.T2.1): persist each daemon's catalog row, then send
  /// `.Detach` so the daemons survive the app's exit. The next launch
  /// re-`connect(2)`s the recorded sockets in `SessionReaper.sweep`.
  ///
  /// Agent state (if a provider is wired) is captured into the same
  /// catalog write so the next launch can seed `AgentStateStore` from
  /// liveness-checked rows — only agent processes that survived the
  /// quit count, ones we restart fresh otherwise.
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
    var agents: [String: PersistedAgentRecord] = [:]
    if let provider = agentSnapshotProvider {
      for record in provider() {
        agents[record.paneID.raw.uuidString] = record
      }
    }
    persist(catalog: SessionCatalog(
      version: SessionCatalog.currentVersion,
      sessions: sessions,
      agents: agents
    ))

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
  /// All `.Snapshot` round-trips are dispatched in parallel and share
  /// one wall-clock deadline so a single hung daemon cannot serialise
  /// the rest. Without parallelism N panes × 5 s/pane could stall quit
  /// for 5N seconds; with it, total wait is bounded by the slowest
  /// straggler (capped at the shared budget). Stragglers are logged
  /// and skipped — losing one pane's snapshot is preferable to
  /// blocking termination.
  private func snapshotTier(_ liveClients: [ZmxClient]) {
    parallelSnapshot(liveClients)
    // Reset the catalog so a prior live-tier write does not survive into
    // the next launch's `SessionReaper.sweep` — the daemons it would
    // reference are now gone. Snapshot-tier resume keys off the `.snap`
    // files instead.
    persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: [:]))
  }

  /// Fan out `client.snapshot()` across every live client, then spin
  /// the runloop until every slot is populated or the shared deadline
  /// elapses. `willTerminate` runs on the main actor and
  /// `ZmxClient.snapshot()` is itself MainActor-isolated, so we cannot
  /// block on a semaphore — that would deadlock the actor before the
  /// daemon's `EOF` callback can hop back onto it. Spinning
  /// `RunLoop.main` keeps the MainActor servicing background hops
  /// (the read-loop EOF handoff, the continuation resume) so each
  /// snapshot can actually finish.
  private func parallelSnapshot(_ liveClients: [ZmxClient]) {
    guard !liveClients.isEmpty else { return }
    let results = liveClients.map { _ in SnapshotResult() }
    for (client, slot) in zip(liveClients, results) {
      Task { @MainActor in
        do {
          let url = try await client.snapshot()
          slot.value = .success(url)
        } catch {
          slot.value = .failure(error)
        }
      }
    }
    let deadline = Date().addingTimeInterval(Self.snapshotTimeoutSeconds)
    while results.contains(where: { $0.value == nil }) && Date() < deadline {
      // Service one batch of pending events on the main runloop. Capped
      // at 50 ms so a stalled snapshot is still bounded by the outer
      // deadline rather than parking inside Foundation indefinitely.
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    for (client, slot) in zip(liveClients, results) {
      switch slot.value {
      case .success:
        continue
      case .failure(let error):
        logger.error(
          "snapshot failed for pane \(client.paneID, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      case .none:
        logger.error(
          "snapshot timed out for pane \(client.paneID, privacy: .public) (shared \(Self.snapshotTimeoutSeconds)s budget exhausted)"
        )
      }
    }
  }

  /// Shared wall-clock budget for the fan-out `.Snapshot` round-trip.
  /// Applies to the whole batch — stragglers past this point are
  /// logged and skipped so the rest of the snapshots still land.
  private static let snapshotTimeoutSeconds: TimeInterval = 5.0

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
      try coordinator.replace(catalog)
    } catch {
      logger.error(
        "Failed to persist sessions.json on quit: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
