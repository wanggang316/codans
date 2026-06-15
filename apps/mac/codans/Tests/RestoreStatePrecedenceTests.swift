import Foundation
import Testing
import CodansCore

@testable import Codans

/// Named consumer-side precedence regression guards for the launch-time
/// restore wiring (M2, `restore-state-precedence`). These pin the SPECIFIC
/// precedence outcomes that `AppState.derivePendingRestores` must honour
/// once `SessionReaper.mergeSnapshotsIntoStates` has resolved each pane to
/// a single `SessionState`. They are deliberately distinct from
/// `AppRestoreThreadingTests.derivesOnlySnapshotStates` (a generic mixed
/// map): each test here isolates one precedence rule so a regression names
/// the rule it broke.
///
/// Scope boundary: the reaper OWNS the upstream resolution (deleting a
/// stale `.snap` when the daemon is `.alive`, aging out old `.snap` files,
/// reaping orphan sockets). This suite only asserts what the CONSUMER does
/// with an already-resolved map. Reaper-owned and runtime-only facets
/// (aging, on-disk file reaping, live PID-differs) are verified by the
/// reaper's own logic and the M2 user-test stage, not faked here.
@MainActor
struct RestoreStatePrecedenceTests {
  private static func session(_ paneID: PaneID) -> Session {
    Session(
      paneID: paneID,
      socketPath: "/tmp/\(paneID.raw.uuidString).sock",
      pid: 4242,
      createdAt: Date(timeIntervalSince1970: 0),
      lastAttachedAt: Date(timeIntervalSince1970: 0),
      command: ["/bin/zsh"],
      cwd: "/Users/test",
      zmxVersion: "0.0.0"
    )
  }

  /// VAL-RESTORE-008 (consumer side): an alive daemon trumps a stale snap.
  /// The reaper resolves a paneID that conceptually had BOTH a live daemon
  /// and a leftover `<paneID>.snap` to a single `.alive` state (it deletes
  /// the snap — see `mergeSnapshotsIntoStates`). The consumer must then
  /// derive NO pendingRestore for that pane, so the surviving daemon is
  /// reattached without a second, snapshot-driven restore being applied
  /// on top of it (no double-apply).
  @Test
  func aliveDaemonExcludedSoStaleSnapIsNeverReApplied() {
    let alivePane = PaneID()
    let states: [PaneID: SessionState] = [
      alivePane: .alive(Self.session(alivePane))
    ]

    let restores = AppState.derivePendingRestores(from: states)

    #expect(restores[alivePane] == nil)
    #expect(restores.isEmpty)
  }

  /// VAL-RESTORE-010 (consumer side): a kill-fallback pane cold-starts
  /// alongside restored siblings. A `.dead` state (daemon gone, no snap)
  /// must derive NO pendingRestore — that pane cold-starts — while a
  /// sibling `.snapshot(url)` in the SAME sweep map DOES derive a restore.
  /// Asserts the two outcomes are independent: the dead pane's absence
  /// does not suppress the sibling's restore, and the sibling's presence
  /// does not leak a restore onto the dead pane (partial restore, no
  /// cross-contamination of the derived map).
  @Test
  func deadPaneColdStartsWhileSnapshotSiblingRestores() {
    let deadPane = PaneID()
    let snapPane = PaneID()
    let snapURL = URL(fileURLWithPath: "/snaps/\(snapPane.raw.uuidString).snap")
    let states: [PaneID: SessionState] = [
      deadPane: .dead(Self.session(deadPane)),
      snapPane: .snapshot(snapURL),
    ]

    let restores = AppState.derivePendingRestores(from: states)

    #expect(restores[deadPane] == nil)
    #expect(restores[snapPane] == snapURL)
    #expect(restores == [snapPane: snapURL])
  }

  /// VAL-RESTORE-011 (mis-binding guard): an orphan/leftover snap is keyed
  /// by its OWN paneID and can never bind to another pane. With multiple
  /// `.snapshot(url)` entries, each derived restore maps its OWN paneID to
  /// its OWN url — no key collision, no URL swapped onto the wrong pane.
  /// (A pendingRestore for a paneID that is not a live hierarchy pane is
  /// simply never consumed, because `ensureSurface` is only called for
  /// panes that exist; that runtime guard is exercised at the user-test
  /// stage. Here we pin the keying invariant the binding relies on.)
  @Test
  func eachSnapshotKeyedByOwnPaneIDNoMisBinding() {
    let paneA = PaneID()
    let paneB = PaneID()
    let paneC = PaneID()
    let urlA = URL(fileURLWithPath: "/snaps/\(paneA.raw.uuidString).snap")
    let urlB = URL(fileURLWithPath: "/snaps/\(paneB.raw.uuidString).snap")
    let urlC = URL(fileURLWithPath: "/snaps/\(paneC.raw.uuidString).snap")
    let states: [PaneID: SessionState] = [
      paneA: .snapshot(urlA),
      paneB: .snapshot(urlB),
      paneC: .snapshot(urlC),
    ]

    let restores = AppState.derivePendingRestores(from: states)

    #expect(restores == [paneA: urlA, paneB: urlB, paneC: urlC])
    #expect(restores[paneA] == urlA)
    #expect(restores[paneB] == urlB)
    #expect(restores[paneC] == urlC)
    #expect(restores.count == 3)
  }
}
