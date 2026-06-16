import Foundation
import Testing
import CodansCore

@testable import Codans

/// White-box backing for the launch-time restore wiring (M2,
/// `app-restore-threading`). `bootstrapSessionStack` threads the reaper's
/// per-pane sweep result into `engine.pendingRestores` via
/// `AppState.derivePendingRestores`. These tests pin the derivation: only
/// `.snapshot(url)` states become restore entries, keyed by their paneID,
/// with URLs preserved verbatim — `.alive`/`.dead` are excluded. The
/// runtime end-to-end (PID differs, multi-pane no cross-contamination,
/// full round trip) is verified at the M2 user-test stage + the green
/// bats mechanism; this unit test is the decisive white-box evidence.
@MainActor
struct AppRestoreThreadingTests {
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

  /// A map mixing `.alive`, `.dead`, and `.snapshot` must yield exactly
  /// the snapshot entries — alive/dead are dropped, snapshot URLs are
  /// preserved and keyed by the same paneID.
  @Test
  func derivesOnlySnapshotStates() {
    let alivePane = PaneID()
    let deadPane = PaneID()
    let snapPaneA = PaneID()
    let snapPaneB = PaneID()
    let urlA = URL(fileURLWithPath: "/snaps/\(snapPaneA.raw.uuidString).snap")
    let urlB = URL(fileURLWithPath: "/snaps/\(snapPaneB.raw.uuidString).snap")

    let states: [PaneID: SessionState] = [
      alivePane: .alive(Self.session(alivePane)),
      deadPane: .dead(Self.session(deadPane)),
      snapPaneA: .snapshot(urlA),
      snapPaneB: .snapshot(urlB),
    ]

    let restores = AppState.derivePendingRestores(from: states)

    #expect(restores == [snapPaneA: urlA, snapPaneB: urlB])
    #expect(restores[alivePane] == nil)
    #expect(restores[deadPane] == nil)
  }

  /// An empty sweep result derives an empty restore queue (cold start).
  @Test
  func emptyStatesDeriveEmptyRestores() {
    #expect(AppState.derivePendingRestores(from: [:]).isEmpty)
  }

  /// A sweep with no snapshot tier (only alive/dead) derives nothing —
  /// this is the steady-state reattach path where every pane has a live
  /// daemon and no `.snap` file exists.
  @Test
  func noSnapshotsDeriveEmptyRestores() {
    let alivePane = PaneID()
    let deadPane = PaneID()
    let states: [PaneID: SessionState] = [
      alivePane: .alive(Self.session(alivePane)),
      deadPane: .dead(Self.session(deadPane)),
    ]
    #expect(AppState.derivePendingRestores(from: states).isEmpty)
  }
}
