import Foundation

/// Pure value type that drives the ActiveAgents badge's hover-to-open
/// popover behaviour. The view feeds pointer / click events in via the
/// mutating methods below and reads `desiredOpen` after each call to
/// decide whether the popover should be visible.
///
/// Timing per spec AC-P1..P2 (`docs/product-specs/active-agents-view.md`):
/// - **Hover open delay**: 250 ms of sustained pointer presence on the
///   badge before the popover materialises. A brief sweep across the
///   badge must not trigger an open.
/// - **Hover close delay**: 150 ms grace period after the pointer leaves
///   both the badge AND the popover content area. Re-entering either
///   surface inside the grace window cancels the pending close.
/// - **Click**: bypasses both delays — toggles `desiredOpen` immediately.
///
/// The view supplies its own `Date()` clock via `tick(at:)` after waking
/// from `Task.sleep(...)`. Injecting time keeps the type pure and lets
/// `ActiveAgentsHoverBridgeTests` script the timeline deterministically
/// without spinning real clocks.
///
/// `desiredOpen` is the single source of truth — the view binds its
/// `.popover(isPresented:)` to a derived `@State Bool` mirrored from
/// this field on every state change.
struct HoverIntent: Equatable {
  /// Whether the popover should currently be visible. The view binds its
  /// `.popover(isPresented:)` to this value (mirrored into a SwiftUI
  /// `@State Bool`).
  private(set) var desiredOpen: Bool = false

  /// Pending intent — non-nil while a delayed transition is armed but
  /// not yet committed. Cleared on cancellation or commit.
  private var pending: Pending?

  private enum Pending: Equatable {
    /// Pointer has been over the badge since `since`; commit opens the
    /// popover after 250 ms of sustained presence.
    case open(since: Date)
    /// Pointer has left both badge and popover at `since`; commit
    /// closes the popover after 150 ms.
    case close(since: Date)
  }

  /// Spec AC-P1: 250 ms sustained hover before open.
  static let openDelay: TimeInterval = 0.250
  /// Spec AC-P2: 150 ms grace before close after pointer leaves both
  /// the badge and the popover.
  static let closeDelay: TimeInterval = 0.150

  /// Pointer entered the badge frame. If the popover is already open
  /// (or closing), this cancels a pending close; otherwise it arms a
  /// 250 ms open timer.
  mutating func enterBadge(at now: Date) {
    if desiredOpen {
      // Re-entered while popover is open — kill any pending close.
      pending = nil
      return
    }
    // Arm the open timer (or refresh `since` if already armed — the
    // 250 ms is "since the user last became present").
    pending = .open(since: now)
  }

  /// Pointer left the badge. If the pointer is moving into the popover
  /// content, the view will call `enterPopover(at:)` next tick and
  /// cancel the close. We arm the close speculatively.
  mutating func leaveBadge(at now: Date) {
    if desiredOpen {
      pending = .close(since: now)
    } else {
      // Open never committed — discard the pending open.
      pending = nil
    }
  }

  /// Pointer entered the popover content area. Cancels any pending
  /// close and keeps the popover open.
  mutating func enterPopover(at _: Date) {
    if desiredOpen {
      pending = nil
    }
  }

  /// Pointer left the popover content area. Arms a 150 ms close timer
  /// — re-entering either the badge or the popover before the timer
  /// fires cancels it.
  mutating func leavePopover(at now: Date) {
    if desiredOpen {
      pending = .close(since: now)
    }
  }

  /// Time advanced to `now`. Commits any pending transition whose
  /// deadline has elapsed. The view calls this from a `Task.sleep`
  /// continuation that wakes at the deadline.
  mutating func tick(at now: Date) {
    switch pending {
    case .open(let since):
      if now.timeIntervalSince(since) >= Self.openDelay {
        desiredOpen = true
        pending = nil
      }
    case .close(let since):
      if now.timeIntervalSince(since) >= Self.closeDelay {
        desiredOpen = false
        pending = nil
      }
    case nil:
      break
    }
  }

  /// User clicked the badge. Toggles the popover immediately, bypassing
  /// both delays per spec ("the badge stays clickable: clicking it
  /// toggles the popover open immediately (no hover delay)").
  mutating func clickBadge() {
    desiredOpen.toggle()
    pending = nil
  }

  /// External dismissal — e.g. the popover's `.popover(isPresented:)`
  /// closure fired because the user clicked outside the popover.
  /// Synchronises `desiredOpen` so the next hover doesn't reopen
  /// against a stale-true state.
  mutating func dismiss() {
    desiredOpen = false
    pending = nil
  }

  /// Deadline of any currently-armed pending transition (`nil` if no
  /// transition is pending). The view's `Task.sleep` schedule reads
  /// this to know when to call `tick(at:)`.
  var pendingDeadline: Date? {
    switch pending {
    case .open(let since): return since.addingTimeInterval(Self.openDelay)
    case .close(let since): return since.addingTimeInterval(Self.closeDelay)
    case nil: return nil
    }
  }
}
