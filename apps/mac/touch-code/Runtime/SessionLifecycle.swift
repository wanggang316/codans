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

  /// Capture every live `ZmxClient`'s daemon metadata into a fresh
  /// `SessionCatalog`, flush it to disk synchronously, then send `.detach`
  /// on each client so the daemons survive the parent process exit.
  ///
  /// Order is load-bearing: persist BEFORE detach. A crash between steps
  /// still leaves the next launch with enough information to find the
  /// surviving daemons; a crash before persist leaves nothing, which is
  /// no worse than today's behaviour.
  func detachAllForQuit() {
    let liveClients = collectLiveClients()
    if liveClients.isEmpty {
      // Nothing to record — but we still write an empty catalog so the
      // next launch sees a deterministic file (rather than stale entries
      // from a prior run with surviving daemons that have since died).
      persist(catalog: SessionCatalog(version: SessionCatalog.currentVersion, sessions: [:]))
      return
    }

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

  /// Walk the catalog top-down and pull out every `ZmxClient` whose pane
  /// still has a live `PaneSurface` registered with the runtime. Surfaces
  /// can lag behind the catalog when tab activation is lazy, so this is
  /// the only path that reliably enumerates the running daemons.
  private func collectLiveClients() -> [ZmxClient] {
    guard let runtime = ghosttyRuntime else { return [] }
    var clients: [ZmxClient] = []
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          for pane in tab.panes {
            if let surface = runtime.surface(for: pane.id) {
              clients.append(surface.zmxClient)
            }
          }
        }
      }
    }
    return clients
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
