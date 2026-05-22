import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Unit tests for `SortedEntriesProvider.sorted(_:)`. Pure mapping —
/// no SwiftUI, no live registry. We build `AgentEntry` values directly
/// and assert on the output order.
///
/// The triage priority surfaced by the popover is `waitingForInput >
/// finished > loading > idle` (deliberately distinct from the registry's
/// derive priority — see the helper's doc comment for why).
@MainActor
struct SortedEntriesProviderTests {
  /// Empty input → empty output. Sanity case; protects against
  /// degenerate sort behaviour.
  @Test
  func emptyInputYieldsEmptyOutput() {
    let result = SortedEntriesProvider.sorted([:])
    #expect(result.isEmpty)
  }

  /// All four states present → output is ordered `waitingForInput,
  /// finished, loading, idle`. Each entry shares the same
  /// `lastTransitionAt` so only the primary sort key matters here.
  @Test
  func primaryStateOrderIsWaitingFinishedLoadingIdle() {
    let now = Date(timeIntervalSince1970: 1_000)
    let pWait = PaneID()
    let pLoad = PaneID()
    let pFin = PaneID()
    let pIdle = PaneID()

    let entries: [PaneID: AgentRegistry.AgentEntry] = [
      pIdle: .init(kind: .claudeCode, sessionID: nil, state: .idle, lastTransitionAt: now),
      pLoad: .init(kind: .codex, sessionID: nil, state: .loading, lastTransitionAt: now),
      pWait: .init(kind: .pi, sessionID: nil, state: .waitingForInput, lastTransitionAt: now),
      pFin: .init(kind: .claudeCode, sessionID: nil, state: .finished, lastTransitionAt: now),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.entry.state) == [.waitingForInput, .finished, .loading, .idle])
  }

  /// Same state, different `lastTransitionAt` — most-recent first.
  /// Three `.loading` entries staggered 1s apart.
  @Test
  func sameStateOrdersByLastTransitionDescending() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let pOld = PaneID()
    let pMid = PaneID()
    let pNew = PaneID()

    let entries: [PaneID: AgentRegistry.AgentEntry] = [
      pOld: .init(kind: .claudeCode, sessionID: nil, state: .loading, lastTransitionAt: t0),
      pMid: .init(kind: .codex, sessionID: nil, state: .loading, lastTransitionAt: t0.addingTimeInterval(5)),
      pNew: .init(kind: .pi, sessionID: nil, state: .loading, lastTransitionAt: t0.addingTimeInterval(10)),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.paneID) == [pNew, pMid, pOld])
  }

  /// Equal `lastTransitionAt` → tie-break by `paneID.raw.uuidString`
  /// ascending. Documented behaviour; protects against any
  /// hash-order-of-dictionary nondeterminism.
  @Test
  func tieBreakUsesPaneIDAscending() {
    let now = Date(timeIntervalSince1970: 1_000)
    // Construct UUIDs in a known order. `00000…` sorts ahead of `ffffff…`.
    let lo = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let hi = PaneID(raw: UUID(uuidString: "ffffffff-ffff-ffff-ffff-fffffffffff0")!)

    let entries: [PaneID: AgentRegistry.AgentEntry] = [
      hi: .init(kind: .codex, sessionID: nil, state: .loading, lastTransitionAt: now),
      lo: .init(kind: .claudeCode, sessionID: nil, state: .loading, lastTransitionAt: now),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.paneID) == [lo, hi])
  }

  /// Combined sort: across-state ordering wins over within-state. A
  /// fresh `.idle` (transitioned now) still sorts below a stale
  /// `.waitingForInput` (transitioned an hour ago).
  @Test
  func stateOrderBeatsTransitionAge() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let staleWaiting = PaneID()
    let freshIdle = PaneID()

    let entries: [PaneID: AgentRegistry.AgentEntry] = [
      freshIdle: .init(kind: .codex, sessionID: nil, state: .idle, lastTransitionAt: t0.addingTimeInterval(3_600)),
      staleWaiting: .init(kind: .claudeCode, sessionID: nil, state: .waitingForInput, lastTransitionAt: t0),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.paneID) == [staleWaiting, freshIdle])
  }
}
