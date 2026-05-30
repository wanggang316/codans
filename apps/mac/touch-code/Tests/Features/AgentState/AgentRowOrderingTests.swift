import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Unit tests for `AgentRowOrdering` — the pure membership + significance
/// helpers behind the Agents View's stable ordering. No SwiftUI, no live
/// registry; entries are built directly.
@MainActor
struct AgentRowOrderingTests {
  private func entry(
    _ state: AgentStateStore.AgentRuntimeState,
    at t: TimeInterval = 0
  ) -> AgentStateStore.AgentEntry {
    .init(
      kind: .claudeCode,
      sessionID: nil,
      state: state,
      lastTransitionAt: Date(timeIntervalSince1970: t)
    )
  }

  // MARK: - reconcileMembership

  /// Departed panes drop out; surviving panes keep their relative order.
  @Test
  func reconcileDropsDepartedKeepsSurvivorOrder() {
    let a = PaneID()
    let b = PaneID()
    let c = PaneID()
    let entries: [PaneID: AgentStateStore.AgentEntry] = [a: entry(.working), c: entry(.idle)]
    let next = AgentRowOrdering.reconcileMembership(order: [a, b, c], entries: entries)
    #expect(next == [a, c])
  }

  /// Newcomers append at the end; existing rows do not move.
  @Test
  func reconcileAppendsNewcomersAtEnd() {
    let a = PaneID()
    let b = PaneID()
    let entries: [PaneID: AgentStateStore.AgentEntry] = [a: entry(.idle), b: entry(.idle)]
    let next = AgentRowOrdering.reconcileMembership(order: [a], entries: entries)
    #expect(next == [a, b])
  }

  /// Unchanged membership is a no-op even when the existing order disagrees
  /// with triage priority — survivors are never re-sorted here.
  @Test
  func reconcileIsIdempotentWhenMembershipUnchanged() {
    let a = PaneID()
    let b = PaneID()
    let entries: [PaneID: AgentStateStore.AgentEntry] = [a: entry(.blocked), b: entry(.working)]
    let next = AgentRowOrdering.reconcileMembership(order: [b, a], entries: entries)
    #expect(next == [b, a])
  }

  /// With an empty prior order, every entry is a newcomer and the batch is
  /// seeded in triage order (`blocked > finished > working > idle`). This is
  /// the panel's first-appear path.
  @Test
  func emptyOrderSeedsNewcomersInTriageOrder() {
    let blocked = PaneID()
    let working = PaneID()
    let idle = PaneID()
    let entries: [PaneID: AgentStateStore.AgentEntry] = [
      idle: entry(.idle),
      working: entry(.working),
      blocked: entry(.blocked),
    ]
    let next = AgentRowOrdering.reconcileMembership(order: [], entries: entries)
    #expect(next == [blocked, working, idle])
  }

  // MARK: - isOrderSignificant

  /// Any decay into idle is suppressed — the row keeps its place.
  @Test
  func decayIntoIdleIsNotSignificant() {
    #expect(AgentRowOrdering.isOrderSignificant(from: .finished, to: .idle) == false)
    #expect(AgentRowOrdering.isOrderSignificant(from: .working, to: .idle) == false)
    #expect(AgentRowOrdering.isOrderSignificant(from: .blocked, to: .idle) == false)
  }

  /// A no-op transition never reorders.
  @Test
  func sameStateIsNotSignificant() {
    #expect(AgentRowOrdering.isOrderSignificant(from: .working, to: .working) == false)
    #expect(AgentRowOrdering.isOrderSignificant(from: .idle, to: .idle) == false)
  }

  /// Rises into active / finished and lateral moves between them reorder.
  @Test
  func risesAndLateralMovesAreSignificant() {
    #expect(AgentRowOrdering.isOrderSignificant(from: .idle, to: .blocked))
    #expect(AgentRowOrdering.isOrderSignificant(from: .idle, to: .working))
    #expect(AgentRowOrdering.isOrderSignificant(from: .idle, to: .finished))
    #expect(AgentRowOrdering.isOrderSignificant(from: .working, to: .blocked))
    #expect(AgentRowOrdering.isOrderSignificant(from: .working, to: .finished))
    #expect(AgentRowOrdering.isOrderSignificant(from: .finished, to: .working))
  }
}
