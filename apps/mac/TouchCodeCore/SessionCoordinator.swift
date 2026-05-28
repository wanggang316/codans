import Foundation
import os.log

/// Single writer for the in-memory mirror of `sessions.json` and the only
/// path that mutates the on-disk file after launch. `SessionStore` keeps
/// owning the flock, the atomic-rename pipeline, and the load primitive;
/// `SessionCoordinator` sits on top, holds the live catalog, and exposes
/// intent-shaped mutators so the four existing mutation sites (bootstrap,
/// reaper sweep, quit-time lifecycle, `pane.close` IPC) all route through
/// one entry point.
///
/// This layer is a pure refactor today — each mutator preserves the prior
/// synchronous-save semantics. The richer surface (`recordSpawn`,
/// `recordAttach`, `recordDetach`, debounced write-through, agent state)
/// lands in subsequent M6 tasks; the indirection makes those additions
/// touch one file instead of four.
@MainActor
public final class SessionCoordinator {
  private let store: SessionStore
  private var snapshot: SessionCatalog
  private let logger = Logger(
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

  /// Drain any pending debounced save. Pass-through to `SessionStore`
  /// so the quit-time flush goes through one entry point once the
  /// upcoming write-through tier introduces debounced writes.
  public func flushPending() {
    store.flushPending()
  }
}
