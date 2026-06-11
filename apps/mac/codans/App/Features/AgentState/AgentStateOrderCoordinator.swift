import Foundation
import Observation
import CodansCore

/// Owns the *displayed* order of the Agents View, decoupled from
/// `AgentStateStore.entries` (an unordered dictionary). The view renders from
/// `orderedIDs`; this coordinator keeps that array stable and only re-sorts
/// on a debounce, so rapid state churn coalesces into a single animated
/// settle instead of per-transition flicker.
///
/// Behaviour:
/// - Membership (add / remove) is applied immediately on every `reconcile`:
///   newcomers append, departed panes drop, survivors keep their place.
///   Adding or removing an agent never reorders the rest.
/// - A re-sort into triage order (`SortedEntriesProvider`) is scheduled only
///   when an *order-significant* transition occurs (see
///   `AgentRowOrdering.isOrderSignificant`) AND auto-sort is enabled. The
///   schedule is debounced by `debounce` (default 800 ms); successive
///   significant changes extend the window.
/// - When auto-sort is off, no re-sort is ever scheduled: the list holds its
///   current order and only grows / shrinks by membership.
///
/// The view animates order changes via `.animation(_:value: orderedIDs)`, so
/// this type never imports SwiftUI — it mutates `orderedIDs` and lets the
/// view's transaction animate the diff.
@MainActor
@Observable
final class AgentStateOrderCoordinator {
  /// Display order consumed by the view. Survivors first, newcomers
  /// appended; replaced wholesale by a debounced triage sort when armed.
  private(set) var orderedIDs: [PaneID] = []

  /// Last-observed state per pane, used to detect significant transitions
  /// across `reconcile` calls.
  @ObservationIgnored
  private var lastStates: [PaneID: AgentStateStore.AgentRuntimeState] = [:]
  /// Most recent entries snapshot, sorted at debounce-fire time so the
  /// re-sort reflects the latest states rather than a stale capture.
  @ObservationIgnored
  private var latestEntries: [PaneID: AgentStateStore.AgentEntry] = [:]
  @ObservationIgnored
  private var pendingResort: Task<Void, Never>?
  @ObservationIgnored
  private let debounce: Duration

  /// Trailing debounce between an order-significant change and the animated
  /// re-sort. Long enough to absorb a burst of transitions into one settle.
  static let defaultDebounce: Duration = .milliseconds(800)

  init(debounce: Duration = AgentStateOrderCoordinator.defaultDebounce) {
    self.debounce = debounce
  }

  /// Reconcile the display order against a fresh entries snapshot.
  /// `autoSort` mirrors `Settings → General → Agents View → Auto-sort`.
  func reconcile(
    entries: [PaneID: AgentStateStore.AgentEntry],
    autoSort: Bool
  ) {
    latestEntries = entries

    // 1. Immediate membership: drop departed, append newcomers.
    let nextOrder = AgentRowOrdering.reconcileMembership(order: orderedIDs, entries: entries)
    if nextOrder != orderedIDs {
      orderedIDs = nextOrder
    }

    // 2. Detect an order-significant change versus the last snapshot.
    var significant = false
    for (id, entry) in entries {
      if let previous = lastStates[id] {
        if AgentRowOrdering.isOrderSignificant(from: previous, to: entry.state) {
          significant = true
        }
      } else if entry.state != .idle {
        // A newcomer that arrives already active / finished is worth
        // bubbling to its triage slot.
        significant = true
      }
    }
    lastStates = entries.mapValues(\.state)

    // 3. Arm / suppress the debounced triage re-sort.
    if autoSort {
      if significant { scheduleResort() }
    } else {
      cancelPendingResort()
    }
  }

  /// Called when the auto-sort setting itself flips. Turning it on settles
  /// the list into triage order (debounced); turning it off freezes the
  /// current order and cancels any pending re-sort.
  func autoSortChanged(
    to autoSort: Bool,
    entries: [PaneID: AgentStateStore.AgentEntry]
  ) {
    latestEntries = entries
    lastStates = entries.mapValues(\.state)
    if autoSort {
      scheduleResort()
    } else {
      cancelPendingResort()
    }
  }

  private func scheduleResort() {
    pendingResort?.cancel()
    pendingResort = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.debounce)
      guard !Task.isCancelled else { return }
      self.applyResort()
    }
  }

  private func cancelPendingResort() {
    pendingResort?.cancel()
    pendingResort = nil
  }

  private func applyResort() {
    let sorted = SortedEntriesProvider.sorted(latestEntries).map(\.paneID)
    if sorted != orderedIDs {
      orderedIDs = sorted
    }
  }

  #if DEBUG
    /// Test seam: await the in-flight debounced re-sort, if any, so tests can
    /// assert on the settled order deterministically instead of polling.
    func awaitPendingResortForTests() async {
      await pendingResort?.value
    }
  #endif
}
