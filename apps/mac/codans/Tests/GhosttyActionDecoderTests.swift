import Foundation
import GhosttyKit
import Testing
import CodansCore

@testable import Codans

/// Unit tests for the pure C-enum → Swift-enum helpers inside
/// `GhosttyActionDecoder`. These helpers are the only slices of the 65-case
/// action switch that are reachable without constructing a full
/// `ghostty_action_s` C union; integration coverage of the switch itself
/// lives in the manual smoke checklist.
///
/// Visibility note: the six `decode*` helpers are `internal static` (not
/// `fileprivate`) so `@testable` can cross the boundary.
@MainActor
struct GhosttyActionDecoderTests {

  // MARK: - decodeCloseTabMode

  @Test
  func closeTabModeThisMapsToThis() {
    #expect(
      GhosttyActionDecoder.decodeCloseTabMode(GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) == .this
    )
  }

  @Test
  func closeTabModeOtherMapsToOther() {
    #expect(
      GhosttyActionDecoder.decodeCloseTabMode(GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER) == .other
    )
  }

  @Test
  func closeTabModeRightMapsToRight() {
    #expect(
      GhosttyActionDecoder.decodeCloseTabMode(GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT) == .right
    )
  }

  @Test
  func closeTabModeUnknownReturnsNil() {
    let bogus = ghostty_action_close_tab_mode_e(rawValue: 9999)
    #expect(GhosttyActionDecoder.decodeCloseTabMode(bogus) == nil)
  }

  // MARK: - decodeNewSplitDirection
  //
  // Four C directions map 1:1 to four Swift cases.

  @Test
  func newSplitDirectionRightMapsToRight() {
    #expect(
      GhosttyActionDecoder.decodeNewSplitDirection(GHOSTTY_SPLIT_DIRECTION_RIGHT) == .right
    )
  }

  @Test
  func newSplitDirectionLeftMapsToLeft() {
    #expect(
      GhosttyActionDecoder.decodeNewSplitDirection(GHOSTTY_SPLIT_DIRECTION_LEFT) == .left
    )
  }

  @Test
  func newSplitDirectionUpMapsToUp() {
    #expect(
      GhosttyActionDecoder.decodeNewSplitDirection(GHOSTTY_SPLIT_DIRECTION_UP) == .up
    )
  }

  @Test
  func newSplitDirectionDownMapsToDown() {
    #expect(
      GhosttyActionDecoder.decodeNewSplitDirection(GHOSTTY_SPLIT_DIRECTION_DOWN) == .down
    )
  }

  @Test
  func newSplitDirectionUnknownReturnsNil() {
    let bogus = ghostty_action_split_direction_e(rawValue: 9999)
    #expect(GhosttyActionDecoder.decodeNewSplitDirection(bogus) == nil)
  }

  // MARK: - decodeGotoSplitDirection

  @Test
  func gotoSplitPreviousMapsToPrevious() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_PREVIOUS) == .previous
    )
  }

  @Test
  func gotoSplitNextMapsToNext() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_NEXT) == .next
    )
  }

  @Test
  func gotoSplitUpMapsToUp() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_UP) == .up
    )
  }

  @Test
  func gotoSplitDownMapsToDown() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_DOWN) == .down
    )
  }

  @Test
  func gotoSplitLeftMapsToLeft() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_LEFT) == .left
    )
  }

  @Test
  func gotoSplitRightMapsToRight() {
    #expect(
      GhosttyActionDecoder.decodeGotoSplitDirection(GHOSTTY_GOTO_SPLIT_RIGHT) == .right
    )
  }

  @Test
  func gotoSplitUnknownReturnsNil() {
    let bogus = ghostty_action_goto_split_e(rawValue: 9999)
    #expect(GhosttyActionDecoder.decodeGotoSplitDirection(bogus) == nil)
  }

  // MARK: - decodeResizeSplitDirection

  @Test
  func resizeSplitUpMapsToUp() {
    #expect(
      GhosttyActionDecoder.decodeResizeSplitDirection(GHOSTTY_RESIZE_SPLIT_UP) == .up
    )
  }

  @Test
  func resizeSplitDownMapsToDown() {
    #expect(
      GhosttyActionDecoder.decodeResizeSplitDirection(GHOSTTY_RESIZE_SPLIT_DOWN) == .down
    )
  }

  @Test
  func resizeSplitLeftMapsToLeft() {
    #expect(
      GhosttyActionDecoder.decodeResizeSplitDirection(GHOSTTY_RESIZE_SPLIT_LEFT) == .left
    )
  }

  @Test
  func resizeSplitRightMapsToRight() {
    #expect(
      GhosttyActionDecoder.decodeResizeSplitDirection(GHOSTTY_RESIZE_SPLIT_RIGHT) == .right
    )
  }

  @Test
  func resizeSplitUnknownReturnsNil() {
    let bogus = ghostty_action_resize_split_direction_e(rawValue: 9999)
    #expect(GhosttyActionDecoder.decodeResizeSplitDirection(bogus) == nil)
  }

  // MARK: - decodeGotoTabTarget
  //
  // `ghostty_action_goto_tab_e` is a signed-rawValue C enum where
  // PREVIOUS=-1, NEXT=-2, LAST=-3; any other value is interpreted as an
  // absolute tab index.

  @Test
  func gotoTabPreviousMapsToPrevious() {
    #expect(
      GhosttyActionDecoder.decodeGotoTabTarget(GHOSTTY_GOTO_TAB_PREVIOUS) == .previous
    )
  }

  @Test
  func gotoTabNextMapsToNext() {
    #expect(
      GhosttyActionDecoder.decodeGotoTabTarget(GHOSTTY_GOTO_TAB_NEXT) == .next
    )
  }

  @Test
  func gotoTabLastMapsToLast() {
    #expect(
      GhosttyActionDecoder.decodeGotoTabTarget(GHOSTTY_GOTO_TAB_LAST) == .last
    )
  }

  @Test
  func gotoTabZeroMapsToIndexZero() {
    let target = ghostty_action_goto_tab_e(rawValue: 0)
    #expect(GhosttyActionDecoder.decodeGotoTabTarget(target) == .index(0))
  }

  @Test
  func gotoTabPositiveValueMapsToIndex() {
    let target = ghostty_action_goto_tab_e(rawValue: 7)
    #expect(GhosttyActionDecoder.decodeGotoTabTarget(target) == .index(7))
  }

  // MARK: - decodeGotoWindowTarget
  //
  // libghostty emits only PREVIOUS/NEXT today. `.last`/`.index` on
  // `GotoWindowTarget` are reserved for future IPC, so the
  // "unknown" case here returns nil rather than synthesising an index.

  @Test
  func gotoWindowPreviousMapsToPrevious() {
    #expect(
      GhosttyActionDecoder.decodeGotoWindowTarget(GHOSTTY_GOTO_WINDOW_PREVIOUS) == .previous
    )
  }

  @Test
  func gotoWindowNextMapsToNext() {
    #expect(
      GhosttyActionDecoder.decodeGotoWindowTarget(GHOSTTY_GOTO_WINDOW_NEXT) == .next
    )
  }

  @Test
  func gotoWindowUnknownReturnsNil() {
    let bogus = ghostty_action_goto_window_e(rawValue: 9999)
    #expect(GhosttyActionDecoder.decodeGotoWindowTarget(bogus) == nil)
  }
}
