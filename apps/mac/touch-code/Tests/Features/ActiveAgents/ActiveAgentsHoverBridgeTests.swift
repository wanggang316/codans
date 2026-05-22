import Foundation
import Testing

@testable import touch_code

/// Behavioural coverage for `HoverIntent`, the pure value type that
/// drives the ActiveAgents badge popover. The badge view feeds pointer
/// events in and reads `desiredOpen` to bind SwiftUI's
/// `.popover(isPresented:)`. The 250 ms open delay + 150 ms close
/// grace are spec AC-P1 / AC-P2 (see
/// `docs/product-specs/active-agents-view.md`).
///
/// Time is scripted via the `at:` parameter on every entry point and
/// the `tick(at:)` continuation — no real clock involvement, no
/// XCTestExpectation timeouts. Each test reads as a small timeline.
struct ActiveAgentsHoverBridgeTests {
  private let t0 = Date(timeIntervalSince1970: 1_000)

  /// UT-AA-P-001 (quick sweep): pointer enters badge but leaves before
  /// 250 ms have elapsed → popover never opens.
  @Test
  func quickSweepBelowOpenDelayDoesNotOpen() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    // Tick at 200 ms — under the 250 ms threshold.
    intent.tick(at: t0.addingTimeInterval(0.2))
    #expect(intent.desiredOpen == false)
    // User leaves the badge before the open commits.
    intent.leaveBadge(at: t0.addingTimeInterval(0.2))
    // Tick well past the original deadline. With pending cleared on
    // leave, no commit must fire.
    intent.tick(at: t0.addingTimeInterval(1.0))
    #expect(intent.desiredOpen == false)
  }

  /// UT-AA-P-001 (sustained hover): pointer parked on badge for ≥250 ms
  /// → popover opens.
  @Test
  func sustainedHoverPastOpenDelayOpens() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    intent.tick(at: t0.addingTimeInterval(0.250))
    #expect(intent.desiredOpen == true)
  }

  /// UT-AA-P-002 (bridge stays open): popover is open, pointer leaves
  /// the badge but enters the popover within the 150 ms close grace
  /// → popover stays open.
  @Test
  func pointerCrossesBadgeIntoPopoverWithinGraceStaysOpen() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    intent.tick(at: t0.addingTimeInterval(0.250))
    #expect(intent.desiredOpen == true)

    // Leave badge at t = 0.300; enter popover at t = 0.350 (50 ms
    // later, well inside the 150 ms grace).
    intent.leaveBadge(at: t0.addingTimeInterval(0.300))
    intent.enterPopover(at: t0.addingTimeInterval(0.350))
    // Tick past the original close deadline (0.300 + 0.150 = 0.450).
    intent.tick(at: t0.addingTimeInterval(0.500))
    #expect(intent.desiredOpen == true)
  }

  /// UT-AA-P-002 (outside-grace close): popover is open, pointer
  /// leaves both surfaces and stays out past 150 ms → popover closes.
  @Test
  func pointerLeavesBothPastCloseDelayCloses() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    intent.tick(at: t0.addingTimeInterval(0.250))
    #expect(intent.desiredOpen == true)

    intent.leaveBadge(at: t0.addingTimeInterval(0.300))
    intent.enterPopover(at: t0.addingTimeInterval(0.310))
    intent.leavePopover(at: t0.addingTimeInterval(0.400))
    // 0.400 + 0.150 = 0.550 — tick at 0.560 to commit.
    intent.tick(at: t0.addingTimeInterval(0.560))
    #expect(intent.desiredOpen == false)
  }

  /// Click bypass: a fresh click on the badge opens the popover
  /// immediately, no 250 ms wait, no pending timer.
  @Test
  func clickOpensImmediately() {
    var intent = HoverIntent()
    intent.clickBadge()
    #expect(intent.desiredOpen == true)
    #expect(intent.pendingDeadline == nil)
  }

  /// Click toggle: clicking the badge while the popover is open closes
  /// it immediately.
  @Test
  func clickWhileOpenClosesImmediately() {
    var intent = HoverIntent()
    intent.clickBadge()
    #expect(intent.desiredOpen == true)
    intent.clickBadge()
    #expect(intent.desiredOpen == false)
    #expect(intent.pendingDeadline == nil)
  }

  /// Re-entering the badge during the 150 ms close grace cancels the
  /// pending close. Same surface as `enterPopover` but applies to the
  /// badge frame — keyboard-driven hover oscillation must not close
  /// the popover.
  @Test
  func reEnteringBadgeDuringGraceCancelsClose() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    intent.tick(at: t0.addingTimeInterval(0.250))
    intent.leaveBadge(at: t0.addingTimeInterval(0.300))
    // Re-enter at 0.380 (80 ms into the grace).
    intent.enterBadge(at: t0.addingTimeInterval(0.380))
    intent.tick(at: t0.addingTimeInterval(0.500))
    #expect(intent.desiredOpen == true)
  }

  /// `dismiss()` synchronises `desiredOpen` to false and clears any
  /// pending transition — used by the badge view when SwiftUI's
  /// `.popover` writes `isPresented = false` (outside-click /
  /// system dismissal).
  @Test
  func dismissClearsStateAndPending() {
    var intent = HoverIntent()
    intent.enterBadge(at: t0)
    intent.tick(at: t0.addingTimeInterval(0.250))
    #expect(intent.desiredOpen == true)
    intent.dismiss()
    #expect(intent.desiredOpen == false)
    #expect(intent.pendingDeadline == nil)
  }
}
