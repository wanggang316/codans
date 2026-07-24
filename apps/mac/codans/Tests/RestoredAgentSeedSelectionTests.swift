import CodansCore
import Foundation
import Testing

@testable import Codans

/// Regression guards for `AppState.selectAgentSeeds` — the policy that turns
/// the previous quit's persisted agent snapshot into the seeds handed to
/// `AgentStateStore.seedRestored` at launch.
///
/// The bug these pin: liveness used to be keyed on `coordinator.catalog.sessions`,
/// but the keepRunning quit path persists `sessions: [:]`, so that map is empty
/// at the next launch and the filter dropped EVERY restored agent — a resumed
/// working/blocked agent silently fell back to idle. Liveness is now a direct
/// per-pane daemon-socket probe, modelled here by the injected `isDaemonAlive`
/// predicate so the selection policy is testable without a live socket.
@MainActor
struct RestoredAgentSeedSelectionTests {
  private static func record(
    _ paneID: PaneID,
    kind: String = "claude-code",
    state: String = "working"
  ) -> PersistedAgentRecord {
    PersistedAgentRecord(
      paneID: paneID,
      kindRaw: kind,
      stateRaw: state,
      pid: 0,
      capturedAt: Date(timeIntervalSince1970: 0)
    )
  }

  /// A live daemon with decodable raws is seeded with its persisted state —
  /// the working/blocked badge survives the quit→launch cycle.
  @Test
  func aliveDaemonWithValidRawsIsSeeded() {
    let pane = PaneID()
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane, state: "working")],
      isDaemonAlive: { _ in true }
    )

    #expect(seeds.count == 1)
    #expect(seeds.first?.paneID == pane)
    #expect(seeds.first?.kind == .claudeCode)
    #expect(seeds.first?.state == .working)
  }

  /// The direct regression: a dead daemon drops the record. (Before the fix,
  /// the empty-`catalog.sessions` filter made EVERY record look dead.)
  @Test
  func deadDaemonIsSkipped() {
    let pane = PaneID()
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane)],
      isDaemonAlive: { _ in false }
    )

    #expect(seeds.isEmpty)
  }

  /// Liveness is per-pane: only the alive pane's agent is seeded.
  @Test
  func onlyAliveDaemonsAreSeeded() {
    let alive = PaneID()
    let dead = PaneID()
    let seeds = AppState.selectAgentSeeds(
      restored: [
        alive: Self.record(alive, state: "blocked"),
        dead: Self.record(dead, state: "working"),
      ],
      isDaemonAlive: { $0 == alive }
    )

    #expect(seeds.count == 1)
    #expect(seeds.first?.paneID == alive)
    #expect(seeds.first?.state == .blocked)
  }

  /// An unknown `kindRaw` from a future build is dropped, not crashed on.
  @Test
  func unknownKindRawIsSkipped() {
    let pane = PaneID()
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane, kind: "future-agent-9000")],
      isDaemonAlive: { _ in true }
    )

    #expect(seeds.isEmpty)
  }

  /// An unknown `stateRaw` from a future build is dropped, not crashed on.
  @Test
  func unknownStateRawIsSkipped() {
    let pane = PaneID()
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane, state: "hyperfocused")],
      isDaemonAlive: { _ in true }
    )

    #expect(seeds.isEmpty)
  }

  /// Dedup: when the launch sweep already covered the pane, its verdict is
  /// reused and the socket is NOT re-probed. The probe fails the test if it
  /// ever runs for a pane the sweep map already answered.
  @Test
  func knownLivenessShortCircuitsProbe() {
    let pane = PaneID()
    var probed = false
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane, state: "working")],
      knownLiveness: [pane: true],
      isDaemonAlive: { _ in
        probed = true
        return false
      }
    )

    #expect(probed == false)
    #expect(seeds.count == 1)
    #expect(seeds.first?.paneID == pane)
  }

  /// A sweep verdict of "dead" drops the record without probing — the sweep
  /// may have kill-recycled the daemon, so a stale live socket read must not
  /// resurrect the badge.
  @Test
  func knownDeadOverridesProbe() {
    let pane = PaneID()
    var probed = false
    let seeds = AppState.selectAgentSeeds(
      restored: [pane: Self.record(pane)],
      knownLiveness: [pane: false],
      isDaemonAlive: { _ in
        probed = true
        return true
      }
    )

    #expect(probed == false)
    #expect(seeds.isEmpty)
  }

  /// A pane the sweep never saw (empty map for that key — e.g. the
  /// keepRunning quit path persists `sessions: [:]`) falls back to the
  /// direct probe, preserving the pre-dedup behavior.
  @Test
  func absentFromKnownLivenessFallsBackToProbe() {
    let seen = PaneID()
    let unseen = PaneID()
    var probedPanes: [PaneID] = []
    let seeds = AppState.selectAgentSeeds(
      restored: [
        seen: Self.record(seen, state: "working"),
        unseen: Self.record(unseen, state: "blocked"),
      ],
      knownLiveness: [seen: true],
      isDaemonAlive: { paneID in
        probedPanes.append(paneID)
        return true
      }
    )

    // Only the pane absent from the sweep map hits the probe.
    #expect(probedPanes == [unseen])
    #expect(seeds.count == 2)
  }
}
