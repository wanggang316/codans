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
/// disabled: it kills each live daemon so nothing is left to reattach to.
/// When resume is enabled the daemons are simply left running — the app
/// exiting is enough. `sessions.json` is written empty either way: daemon
/// liveness is recovered by re-attaching from the persisted Pane list on the
/// next launch, not from a socket catalog.
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

  /// Write the quit-time `sessions.json` and, when resume is disabled, kill
  /// every live daemon.
  ///
  /// - `.keepRunning`: leave the daemons running. The app exiting drops each
  ///   `zmx attach` client; the daemon detaches and keeps its PTY child, so
  ///   the next launch re-attaches to the same session and resumes.
  /// - `.snapshot`: resume is disabled. Kill each live daemon so the next
  ///   launch starts every pane fresh. (The name predates the move to a
  ///   live-only resume model; it now means "do not keep daemons running".)
  func detachAllForQuit(action: QuitAction) {
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
    for surface in surfaces {
      ZmxControlClient.kill(for: surface.paneID)
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
