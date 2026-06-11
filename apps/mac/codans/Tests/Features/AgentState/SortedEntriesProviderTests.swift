import Foundation
import Testing
import CodansCore

@testable import Codans

/// Unit tests for `SortedEntriesProvider.sorted(_:)`. Pure mapping —
/// no SwiftUI, no live registry. We build `AgentEntry` values directly
/// and assert on the output order.
///
/// The triage priority surfaced by the popover is `blocked >
/// finished > working > idle` (deliberately distinct from the registry's
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

  /// All four states present → output is ordered `blocked,
  /// finished, working, idle`. Each entry shares the same
  /// `lastTransitionAt` so only the primary sort key matters here.
  @Test
  func primaryStateOrderIsBlockedFinishedWorkingIdle() {
    let now = Date(timeIntervalSince1970: 1_000)
    let pBlocked = PaneID()
    let pWorking = PaneID()
    let pFin = PaneID()
    let pIdle = PaneID()

    let entries: [PaneID: AgentStateStore.AgentEntry] = [
      pIdle: .init(kind: .claudeCode, sessionID: nil, state: .idle, lastTransitionAt: now),
      pWorking: .init(kind: .codex, sessionID: nil, state: .working, lastTransitionAt: now),
      pBlocked: .init(kind: .pi, sessionID: nil, state: .blocked, lastTransitionAt: now),
      pFin: .init(kind: .claudeCode, sessionID: nil, state: .finished, lastTransitionAt: now),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.entry.state) == [.blocked, .finished, .working, .idle])
  }

  /// Same state, different `lastTransitionAt` — most-recent first.
  /// Three `.working` entries staggered 1s apart.
  @Test
  func sameStateOrdersByLastTransitionDescending() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let pOld = PaneID()
    let pMid = PaneID()
    let pNew = PaneID()

    let entries: [PaneID: AgentStateStore.AgentEntry] = [
      pOld: .init(kind: .claudeCode, sessionID: nil, state: .working, lastTransitionAt: t0),
      pMid: .init(kind: .codex, sessionID: nil, state: .working, lastTransitionAt: t0.addingTimeInterval(5)),
      pNew: .init(kind: .pi, sessionID: nil, state: .working, lastTransitionAt: t0.addingTimeInterval(10)),
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

    let entries: [PaneID: AgentStateStore.AgentEntry] = [
      hi: .init(kind: .codex, sessionID: nil, state: .working, lastTransitionAt: now),
      lo: .init(kind: .claudeCode, sessionID: nil, state: .working, lastTransitionAt: now),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.paneID) == [lo, hi])
  }

  /// Combined sort: across-state ordering wins over within-state. A
  /// fresh `.idle` (transitioned now) still sorts below a stale
  /// `.blocked` (transitioned an hour ago).
  @Test
  func stateOrderBeatsTransitionAge() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let staleBlocked = PaneID()
    let freshIdle = PaneID()

    let entries: [PaneID: AgentStateStore.AgentEntry] = [
      freshIdle: .init(kind: .codex, sessionID: nil, state: .idle, lastTransitionAt: t0.addingTimeInterval(3_600)),
      staleBlocked: .init(kind: .claudeCode, sessionID: nil, state: .blocked, lastTransitionAt: t0),
    ]

    let result = SortedEntriesProvider.sorted(entries)
    #expect(result.map(\.paneID) == [staleBlocked, freshIdle])
  }
}
