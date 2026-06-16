import Foundation
import CodansCore
import os.log

/// Quit-time bridge between the live pane runtime and the per-Pane zmx
/// daemons. Each Pane's shell lives in a daemon that the in-surface
/// `zmx attach` client connects to; when the app exits, those clients die
/// and the daemon reads the disconnect as a detach, keeping its PTY child
/// alive so the next launch can re-`attach` and resume the running shell.
///
/// `detachAllForQuit(action:)` therefore has real work only when resume is
/// disabled: it asks each live daemon to serialize its scrollback to a
/// `<paneID>.snap` and then tears the daemon down, so nothing is left to
/// reattach to. When resume is enabled the daemons are simply left running —
/// the app exiting is enough. `sessions.json` is written empty either way:
/// daemon liveness is recovered by re-attaching from the persisted Pane list
/// on the next launch, not from a socket catalog.
///
/// `detachAllForQuit(action:)` takes a `CodansCore.QuitAction`; `CodansApp`
/// decides which action to pass (from `settings.general.quitAction` or the
/// user's dialog choice) so this component stays a pure mechanism.
@MainActor
final class SessionLifecycle {
  private let manager: HierarchyManager
  private let ghosttyRuntime: GhosttyRuntime?
  private let coordinator: SessionCoordinator
  private let now: () -> Date
  private let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session.lifecycle")
  /// Optional agent-state source for the quit-time catalog write. Set by
  /// AppState once the registry is built. Nil keeps tests and headless
  /// callers from needing to wire it.
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

  /// Number of live pane surfaces. `CodansApp.applicationShouldTerminate`
  /// reads this to decide whether to surface the quit confirmation dialog at
  /// all — zero panes means there is nothing to ask about.
  var liveZmxClientCount: Int {
    ghosttyRuntime?.allLiveSurfaces().count ?? 0
  }

  /// Per-pane snapshot deadline. `ZmxControlClient.snapshot(for:)` rounds the
  /// `Duration` down to whole seconds (it reads only `components.seconds`), so
  /// this must stay a whole-second value; `.seconds(2)` gives every daemon up
  /// to 2 s to serialize its scrollback and close the socket before we fall
  /// back to `.kill`.
  private static let perPaneSnapshotTimeout: Duration = .seconds(2)

  /// Max snapshots in flight at once. Typical quits have 2-8 panes (all fit
  /// in one window), but a large N must not spawn unbounded concurrent socket
  /// I/O — the sliding window in `snapshotLivePanes` caps it here.
  private static let maxConcurrentSnapshots = 8

  /// Write the quit-time `sessions.json` and, when resume is disabled,
  /// serialize each live pane then tear its daemon down.
  ///
  /// - `.keepRunning`: leave the daemons running. The app exiting drops each
  ///   `zmx attach` client; the daemon detaches and keeps its PTY child, so
  ///   the next launch re-attaches to the same session and resumes.
  /// - `.snapshot`: resume is disabled. Serialize each pane (the daemon writes
  ///   its `<paneID>.snap` and exits) then tear the daemon down, so the next
  ///   launch starts every pane fresh from the on-disk snapshot rather than a
  ///   live session. (The name predates the move to a live-only resume model.)
  ///
  /// `async` so the snapshot branch can await each daemon's acknowledgement
  /// (its socket EOF) before the app exits — `CodansApp.applicationShouldTerminate`
  /// drives this from a `.terminateLater` reply so quit waits, bounded, for the
  /// `.snap` files to land. The persist runs synchronously (no suspension)
  /// before the first await, so the `.keepRunning` path stays effectively
  /// unchanged.
  func detachAllForQuit(action: QuitAction) async {
    let surfaces = ghosttyRuntime?.allLiveSurfaces() ?? []

    // Persist agent records so the next launch can liveness-seed
    // `AgentStateStore`; the session map is written empty because resume
    // re-attaches from the Pane list rather than a socket catalog.
    var agents: [String: PersistedAgentRecord] = [:]
    if let provider = agentSnapshotProvider {
      for record in provider() {
        agents[record.paneID.raw.uuidString] = record
      }
    }
    persist(
      catalog: SessionCatalog(
        version: SessionCatalog.currentVersion,
        sessions: [:],
        agents: agents
      ))

    guard case .snapshot = action else { return }
    await snapshotLivePanes(surfaces.map(\.paneID))
  }

  /// Snapshot every live pane with bounded concurrency, then await each
  /// daemon's acknowledgement. For each pane:
  /// - `.acknowledged`: the daemon wrote its `<paneID>.snap` and exited — done.
  /// - `.timedOut`: the daemon never closed the socket within the per-pane
  ///   deadline (e.g. wedged). Fall back to `.kill(for:)` so it does not
  ///   survive the quit, and log a kill-fallback line naming the pane so the
  ///   user-test stage can confirm the snapshotted and kill-fallback sets are
  ///   disjoint.
  /// - `.noSocket`: the daemon was already gone — a clean no-op, NOT a
  ///   fallback (so it is not logged as one).
  ///
  /// Concurrency is capped at `maxConcurrentSnapshots`: a sliding window keeps
  /// at most that many `snapshot(for:)` calls in flight so a large pane count
  /// cannot spawn unbounded socket I/O. Each call is itself deadline-bounded,
  /// so the whole pass completes within roughly
  /// `perPaneSnapshotTimeout × ceil(N / maxConcurrentSnapshots)`.
  private func snapshotLivePanes(_ paneIDs: [PaneID]) async {
    let timeout = Self.perPaneSnapshotTimeout
    let window = Self.maxConcurrentSnapshots
    let logger = self.logger

    await withTaskGroup(of: Void.self) { group in
      var next = 0
      // Prime the window.
      let initial = min(window, paneIDs.count)
      while next < initial {
        let paneID = paneIDs[next]
        group.addTask { await Self.snapshotOne(paneID, timeout: timeout, logger: logger) }
        next += 1
      }
      // Slide: each completed task admits the next pending pane, so the number
      // of in-flight tasks never exceeds `window`.
      while await group.next() != nil {
        guard next < paneIDs.count else { continue }
        let paneID = paneIDs[next]
        group.addTask { await Self.snapshotOne(paneID, timeout: timeout, logger: logger) }
        next += 1
      }
    }
  }

  /// Snapshot a single pane and resolve its outcome. `nonisolated static` so a
  /// task-group child can run it off the `SessionLifecycle` main actor — it
  /// touches no instance state; `ZmxControlClient.snapshot/kill` do their own
  /// socket I/O off the main actor.
  nonisolated private static func snapshotOne(
    _ paneID: PaneID, timeout: Duration, logger: Logger
  ) async {
    switch await ZmxControlClient.snapshot(for: paneID, timeout: timeout) {
    case .acknowledged, .noSocket:
      // `.acknowledged`: snapshot written, daemon exited.
      // `.noSocket`: daemon already gone — clean no-op, not a fallback.
      break
    case .timedOut:
      // Daemon did not acknowledge in time — tear it down so it does not
      // outlive the quit, and record the fallback for the user-test stage.
      ZmxControlClient.kill(for: paneID)
      logger.info(
        "zmx.snapshot kill-fallback pane=\(paneID.raw.uuidString, privacy: .public)"
      )
    }
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
