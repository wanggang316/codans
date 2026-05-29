import Foundation
import os.log

/// Single writer for the in-memory mirror of `sessions.json` and the only
/// path that mutates the on-disk file after launch. `SessionStore` keeps
/// owning the flock, the atomic-rename pipeline, and the load primitive;
/// `SessionCoordinator` sits on top, holds the live catalog, and exposes
/// intent-shaped mutators so the mutation sites (bootstrap, reaper sweep,
/// quit-time lifecycle, `pane.close` IPC, runtime spawn/attach) all route
/// through one entry point.
///
/// `@Observable` so SwiftUI surfaces (e.g. Settings → General's resumable
/// count) can read `catalog.sessions.count` and re-render when bring-up
/// paths upsert rows or when Forget-all clears them.
@Observable
@MainActor
public final class SessionCoordinator {
  @ObservationIgnored private let store: SessionStore
  /// Backing storage for `catalog`. Reads via the public computed property
  /// trigger an `@Observable` access notification; writes via `setSnapshot`
  /// trigger a mutation notification.
  private var snapshot: SessionCatalog
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.touch-code.runtime",
    category: "runtime.session.coordinator"
  )

  public init(store: SessionStore, initial: SessionCatalog) {
    self.store = store
    self.snapshot = initial
  }

  /// In-memory truth. Reads after bootstrap go through here rather than
  /// hitting disk again; the only disk load is the seed passed to `init`.
  public var catalog: SessionCatalog { snapshot }

  /// Replace the catalog wholesale and persist synchronously. Used by
  /// the launch-time reaper after pruning and by the quit-time lifecycle
  /// when it captures the live tier. Errors propagate so callers can
  /// surface the failure their way (the existing call sites log and
  /// continue rather than fail).
  public func replace(_ newCatalog: SessionCatalog) throws {
    snapshot = newCatalog
    try store.saveNow(newCatalog)
  }

  /// Remove a single row and persist synchronously. No-op when absent —
  /// the IPC `pane.close` path needs the operation to be idempotent so a
  /// stale invocation does not error.
  public func recordClose(_ paneID: PaneID) throws {
    let key = paneID.raw.uuidString
    guard snapshot.sessions.removeValue(forKey: key) != nil else { return }
    try store.saveNow(snapshot)
  }

  /// Upsert a row for a daemon that just came up (fresh spawn, restore-
  /// from-snapshot, or reattach). The write goes through the store's
  /// 500 ms debounce, so a burst of bring-ups at launch coalesces into
  /// one fsync. Synchronous teardown paths (`replace`, `recordClose`)
  /// cancel the pending task before writing so this debounced row never
  /// clobbers an immediate save.
  ///
  /// Idempotent: re-recording the same paneID overwrites the row, which
  /// is exactly the semantics we want when a reattach refreshes
  /// `lastAttachedAt` or when a crashed pane respawns with a new pid.
  public func recordLive(_ session: Session) {
    snapshot.sessions[session.paneID.raw.uuidString] = session
    store.scheduleSave(snapshot)
  }

  /// User-initiated "Forget all sessions" from Settings → General.
  /// Calls `killAndUnlink` for every recorded socket so the daemon
  /// exits and the socket file is removed, then clears the in-memory
  /// catalog (sessions + agents) and persists synchronously. The kill
  /// side-effect lives outside `TouchCodeCore` (it speaks zmx's wire
  /// protocol over a raw socket), so the caller injects the closure.
  public func forgetAllSessions(killAndUnlink: (_ socketPath: String) -> Void) throws {
    for session in snapshot.sessions.values {
      killAndUnlink(session.socketPath)
    }
    var cleared = snapshot
    cleared.sessions = [:]
    cleared.agents = [:]
    snapshot = cleared
    try store.saveNow(cleared)
  }

  /// Read-only view of the agent map for the launch-time restore path.
  /// Keyed by `PaneID` so the caller's liveness check (`kill(pid, 0)`)
  /// can correlate against the engine's surviving paneIDs without
  /// re-parsing UUIDs.
  public var restoredAgents: [PaneID: PersistedAgentRecord] {
    var out: [PaneID: PersistedAgentRecord] = [:]
    out.reserveCapacity(snapshot.agents.count)
    for record in snapshot.agents.values {
      out[record.paneID] = record
    }
    return out
  }

  /// Drain any pending debounced save. Pass-through to `SessionStore`
  /// so the quit-time flush routes through one entry point.
  public func flushPending() {
    store.flushPending()
  }
}
