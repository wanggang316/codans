import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural tests for `AgentStateOrderCoordinator`. The debounce is set to
/// `.zero` so the scheduled re-sort fires effectively immediately; tests
/// await the in-flight task via `awaitPendingResortForTests()` so assertions
/// are deterministic rather than time-raced.
///
/// Panes are inserted one tick at a time (single reconcile per id) so the
/// seeded insertion order is deterministic — `reconcileMembership` orders a
/// same-tick batch by triage + paneID, which would otherwise depend on the
/// random UUIDs `PaneID()` produces.
@MainActor
struct AgentStateOrderCoordinatorTests {
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

  /// Membership lands immediately; appending an agent does not reorder.
  @Test
  func membershipAppliesImmediately() {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a])
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a, b])
  }

  /// A significant transition (idle → blocked) bubbles the row to the top
  /// when auto-sort is on.
  @Test
  func significantTransitionResortsWhenOn() async {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: true)
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a, b])
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.blocked)], autoSort: true)
    await coordinator.awaitPendingResortForTests()
    #expect(coordinator.orderedIDs == [b, a])
  }

  /// The core fix: a row promoted to `finished` then decaying to `idle`
  /// keeps its position — the decay does not trigger a re-sort.
  @Test
  func finishedToIdleKeepsPosition() async {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: true)
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a, b])

    // b finishes — significant, bubbles above the idle a.
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.finished)], autoSort: true)
    await coordinator.awaitPendingResortForTests()
    #expect(coordinator.orderedIDs == [b, a])

    // b decays finished → idle — NOT significant, so no re-sort: b stays put.
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: true)
    await coordinator.awaitPendingResortForTests()
    #expect(coordinator.orderedIDs == [b, a])
  }

  /// With auto-sort off, even a significant transition never reorders; the
  /// list holds insertion order.
  @Test
  func autoSortOffNeverReorders() async {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: false)
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: false)
    #expect(coordinator.orderedIDs == [a, b])
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.blocked)], autoSort: false)
    await coordinator.awaitPendingResortForTests()
    #expect(coordinator.orderedIDs == [a, b])
  }

  /// Turning auto-sort on settles the current list into triage order.
  @Test
  func enablingAutoSortSettlesIntoTriageOrder() async {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    // Build [a, b] under auto-sort off with b blocked (would be top if sorted).
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: false)
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.blocked)], autoSort: false)
    #expect(coordinator.orderedIDs == [a, b])

    // Flip auto-sort on → debounced re-sort puts blocked b first.
    coordinator.autoSortChanged(to: true, entries: [a: entry(.idle), b: entry(.blocked)])
    await coordinator.awaitPendingResortForTests()
    #expect(coordinator.orderedIDs == [b, a])
  }

  /// A departed pane is removed from the order on the next reconcile.
  @Test
  func removalDropsRowImmediately() {
    let coordinator = AgentStateOrderCoordinator(debounce: .zero)
    let a = PaneID()
    let b = PaneID()
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: true)
    coordinator.reconcile(entries: [a: entry(.idle), b: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a, b])
    coordinator.reconcile(entries: [a: entry(.idle)], autoSort: true)
    #expect(coordinator.orderedIDs == [a])
  }
}
