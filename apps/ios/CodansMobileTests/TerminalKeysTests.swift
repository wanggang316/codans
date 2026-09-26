import CodansIPC
import Foundation
import Testing
import UIKit

@testable import CodansMobile

/// Modifier latch, key mapping, split order and compose history: the pure
/// parts of the terminal keyboard.
@MainActor
struct TerminalKeysTests {
  private let start = Date(timeIntervalSince1970: 1000)

  @Test
  func tapArmsForOneKey() {
    var latch = ModifierLatch()
    latch.tap(.ctrl, at: start)
    #expect(latch.ctrl == .armed)
    #expect(latch.modifiers == IPC.TerminalKeyModifiers(ctrl: true))
    latch.consume()
    #expect(latch.ctrl == .off)
    #expect(!latch.isActive)
  }

  @Test
  func doubleTapWithinTheWindowLocks() {
    var latch = ModifierLatch()
    latch.tap(.alt, at: start)
    latch.tap(.alt, at: start.addingTimeInterval(0.3))
    #expect(latch.alt == .locked)
    latch.consume()
    latch.consume()
    #expect(latch.alt == .locked)
    latch.tap(.alt, at: start.addingTimeInterval(5))
    #expect(latch.alt == .off)
  }

  @Test
  func slowSecondTapDisarms() {
    var latch = ModifierLatch()
    latch.tap(.ctrl, at: start)
    latch.tap(.ctrl, at: start.addingTimeInterval(ModifierLatch.lockWindow + 0.1))
    #expect(latch.ctrl == .off)
  }

  @Test
  func modifiersLatchIndependently() {
    var latch = ModifierLatch()
    latch.tap(.ctrl, at: start)
    latch.tap(.alt, at: start.addingTimeInterval(0.1))
    latch.tap(.alt, at: start.addingTimeInterval(0.2))
    #expect(latch.ctrl == .armed)
    #expect(latch.alt == .locked)
    latch.consume()
    #expect(latch.modifiers == IPC.TerminalKeyModifiers(alt: true))
  }

  @Test(arguments: [
    (Character("c"), "KeyC", false),
    ("C", "KeyC", true),
    ("~", "Backquote", true),
    ("|", "Backslash", true),
    ("-", "Minus", false),
    ("_", "Minus", true),
    ("5", "Digit5", false),
    ("%", "Digit5", true),
    (" ", "Space", false),
  ])
  func charactersMapToUSKeys(character: Character, code: String, shift: Bool) {
    let key = TerminalKeyMap.key(for: character)
    #expect(key?.code == code)
    #expect(key?.shift == shift)
  }

  @Test
  func chordsCarryNoText() {
    #expect(
      TerminalKeyMap.event(for: "a", mods: IPC.TerminalKeyModifiers(ctrl: true))
        == .key(code: "KeyA", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true)))
    #expect(
      TerminalKeyMap.event(for: "B", mods: IPC.TerminalKeyModifiers(alt: true))
        == .key(code: "KeyB", text: nil, mods: IPC.TerminalKeyModifiers(alt: true, shift: true)))
    #expect(TerminalKeyMap.event(for: "你", mods: IPC.TerminalKeyModifiers(ctrl: true)) == nil)
  }

  @Test(arguments: [
    (UIKeyboardHIDUsage.keyboardA, "KeyA"),
    (.keyboardZ, "KeyZ"),
    (.keyboard1, "Digit1"),
    (.keyboard0, "Digit0"),
    (.keyboardReturnOrEnter, "Enter"),
    (.keyboardEscape, "Escape"),
    (.keyboardDeleteOrBackspace, "Backspace"),
    (.keyboardTab, "Tab"),
    (.keyboardUpArrow, "ArrowUp"),
    (.keyboardLeftArrow, "ArrowLeft"),
    (.keyboardF1, "F1"),
    (.keyboardF12, "F12"),
    (.keyboardPageDown, "PageDown"),
    (.keyboardGraveAccentAndTilde, "Backquote"),
  ])
  func hardwareKeysMapToW3CCodes(usage: UIKeyboardHIDUsage, code: String) {
    #expect(TerminalKeyMap.code(for: usage) == code)
  }

  @Test
  func hardwareModifierFlagsMap() {
    #expect(
      TerminalKeyMap.modifiers([.control, .shift]) == IPC.TerminalKeyModifiers(ctrl: true, shift: true))
    #expect(TerminalKeyMap.modifiers([.command, .alternate]) == IPC.TerminalKeyModifiers(alt: true, super: true))
    #expect(TerminalKeyMap.isNonTextKey("ArrowUp"))
    #expect(!TerminalKeyMap.isNonTextKey("KeyA"))
  }

  @Test
  func shortcutPanelOpensOnTheAgentsPage() {
    #expect(TerminalShortcutPage.defaultPage(forAgent: "claude-code") == .claudeCode)
    #expect(TerminalShortcutPage.defaultPage(forAgent: "codex") == .codex)
    #expect(TerminalShortcutPage.defaultPage(forAgent: nil) == .control)
    let clear = TerminalShortcutPage.claudeCode.shortcuts.first { $0.title == "/clear" }
    #expect(clear?.events == [.text("/clear"), .press("Enter")])
    let modeSwitch = TerminalShortcutPage.claudeCode.shortcuts.first { $0.title == "⇧Tab" }
    #expect(modeSwitch?.events == [.key(code: "Tab", text: nil, mods: IPC.TerminalKeyModifiers(shift: true))])
    let split = TerminalShortcutPage.tmux.shortcuts.first { $0.title == "⌃B %" }
    #expect(
      split?.events == [
        .key(code: "KeyB", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true)),
        .key(code: "Digit5", text: nil, mods: IPC.TerminalKeyModifiers(shift: true)),
      ])
    #expect(TerminalShortcutPage.control.shortcuts.map(\.title) == ["⌃C", "⌃D", "⌃Z", "⌃L", "⌃A", "⌃E", "⌃R", "⌃W"])
  }

  @Test
  func composeHistoryKeepsTwentyNewestWithoutDuplicates() {
    var history = ComposeHistory()
    for index in 0..<25 { history.record("prompt \(index)") }
    history.record("prompt 20")
    history.record("   ")
    #expect(history.entries.count == ComposeHistory.limit)
    #expect(history.entries.first == "prompt 20")
    #expect(history.entries.filter { $0 == "prompt 20" }.count == 1)
    #expect(history.entries.last == "prompt 5")
  }

  @Test
  func dPadRepeatsFasterFurtherOut() {
    #expect(DPadDriver.interval(forDistance: DPadDriver.threshold) == 160)
    #expect(DPadDriver.interval(forDistance: 40) < 160)
    #expect(DPadDriver.interval(forDistance: 400) == 30)
  }

  // MARK: - Split order

  private func pane(_ id: String) -> IPC.PaneSummary {
    IPC.PaneSummary(id: id, handle: nil, title: id, agent: nil, labels: [])
  }

  private func tab(_ panes: [String], layout: IPC.SplitLayoutNode?, focused: String? = nil) -> IPC.TabSummary {
    IPC.TabSummary(id: "T", handle: nil, title: "t", focusedPaneID: focused, panes: panes.map(pane), layout: layout)
  }

  @Test
  func layoutGivesThePaneOrder() {
    // [A | [B / C]]: the list order says C first, the screen says A, B, C.
    let layout = IPC.SplitLayoutNode.split(
      direction: .horizontal, ratio: 0.5, left: .leaf(paneID: "A"),
      right: .split(direction: .vertical, ratio: 0.5, left: .leaf(paneID: "B"), right: .leaf(paneID: "C")))
    let summary = tab(["C", "A", "B"], layout: layout)
    #expect(TerminalLayout.orderedPaneIDs(in: summary) == ["A", "B", "C"])
    #expect(TerminalLayout.pane(1, from: "C", in: summary) == "A")
    #expect(TerminalLayout.pane(-1, from: "A", in: summary) == "C")
  }

  @Test
  func panesTheLayoutMissesFollowInListOrder() {
    let summary = tab(
      ["A", "B", "D"],
      layout: .split(
        direction: .vertical, ratio: 0.5, left: .leaf(paneID: "B"), right: .leaf(paneID: "gone")))
    #expect(TerminalLayout.orderedPaneIDs(in: summary) == ["B", "A", "D"])
    #expect(TerminalLayout.orderedPaneIDs(in: tab(["X", "Y"], layout: nil)) == ["X", "Y"])
    #expect(TerminalLayout.pane(1, from: "X", in: tab(["X"], layout: nil)) == nil)
  }

  @Test
  func iPadStreamsAtMostFourIncludingTheFocusedPane() {
    let ids = ["A", "B", "C", "D", "E", "F"]
    let summary = tab(ids, layout: nil)
    #expect(TerminalLayout.streamedPaneIDs(in: summary, focused: "B") == ["A", "B", "C", "D"])
    #expect(TerminalLayout.streamedPaneIDs(in: summary, focused: "F") == ["A", "B", "C", "F"])
  }

  @Test
  func closingAPaneLandsOnItsNeighbour() {
    let worktree = IPC.WorktreeSummary(
      id: "W", name: "w", branch: nil, isPinned: false, selectedTabID: "T",
      tabs: [
        tab(["A", "B", "C"], layout: nil),
        IPC.TabSummary(id: "T2", handle: nil, title: nil, focusedPaneID: "Z", panes: [pane("Y"), pane("Z")]),
      ])
    #expect(TerminalLayout.paneAfterClosing("B", in: worktree) == "C")
    #expect(TerminalLayout.paneAfterClosing("C", in: worktree) == "B")
    let single = IPC.WorktreeSummary(
      id: "W", name: "w", branch: nil, isPinned: false, selectedTabID: "T",
      tabs: [tab(["A"], layout: nil), worktree.tabs[1]])
    #expect(TerminalLayout.paneAfterClosing("A", in: single) == "Z")
  }

  @Test
  func homeIsShortened() {
    #expect(TerminalLayout.displayPath("/Users/gump/dev/codans") == "~/dev/codans")
    #expect(TerminalLayout.displayPath("/Users/gump") == "~")
    #expect(TerminalLayout.displayPath("/tmp") == "/tmp")
    #expect(TerminalLayout.displayPath(nil) == nil)
  }
}

/// The input view keeps an input method's composition local.
@MainActor
struct TerminalInputViewTests {
  private final class Recorder {
    var texts: [String] = []
    var keys: [String] = []
    var marked: [String?] = []
  }

  private func makeView() -> (TerminalInputView, Recorder) {
    let view = TerminalInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    let recorder = Recorder()
    view.onText = { recorder.texts.append($0) }
    view.onKey = { code, _ in recorder.keys.append(code) }
    view.onMarkedTextChange = { recorder.marked.append($0) }
    return (view, recorder)
  }

  @Test
  func markedTextIsNotSentBeforeCommit() {
    let (view, recorder) = makeView()
    view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0))
    view.deleteBackward()
    #expect(recorder.texts.isEmpty)
    #expect(recorder.keys.isEmpty)
    #expect(view.markedText == "ni")
    #expect(view.markedTextRange != nil)

    // The input method commits the candidate.
    view.insertText("你")
    #expect(recorder.texts == ["你"])
    #expect(view.markedText.isEmpty)
    #expect(recorder.marked == ["n", "ni", "nih", "ni", nil])
  }

  @Test
  func unmarkCommitsTheCompositionAsIs() {
    let (view, recorder) = makeView()
    view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
    view.unmarkText()
    #expect(recorder.texts == ["かな"])
  }

  @Test
  func plainTypingAndBackspaceGoStraightOut() {
    let (view, recorder) = makeView()
    view.insertText("l")
    view.insertText("s")
    view.deleteBackward()
    #expect(recorder.texts == ["l", "s"])
    #expect(recorder.keys == ["Backspace"])
    #expect(view.hasText)
  }

  @Test
  func textTraitsAreOffForATerminal() {
    let (view, _) = makeView()
    #expect(view.autocorrectionType == .no)
    #expect(view.autocapitalizationType == .none)
    #expect(view.smartQuotesType == .no)
    #expect(view.smartDashesType == .no)
    #expect(view.spellCheckingType == .no)
  }
}

/// The renderer keeps the Mac's grid whatever its frame or zoom.
@MainActor
struct MirrorTerminalViewTests {
  @Test
  func gridFollowsTheStreamNotTheFrame() {
    let view = MirrorTerminalView(cols: 80, rows: 24, font: TerminalScreenModel.font)
    let terminal = view.getTerminal()
    #expect(terminal.cols == 80 && terminal.rows == 24)
    for cols in [2, 33, 97, 120, 211] {
      view.setGrid(cols: cols, rows: 41)
      #expect(terminal.cols == cols && terminal.rows == 41)
    }
    view.resetScreen(cols: 100, rows: 30)
    #expect(terminal.cols == 100 && terminal.rows == 30)
    view.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
    view.layoutIfNeeded()
    #expect(terminal.cols == 100 && terminal.rows == 30)
  }

  @Test
  func neverTakesTheKeyboard() {
    let view = MirrorTerminalView(cols: 80, rows: 24, font: TerminalScreenModel.font)
    #expect(!view.canBecomeFirstResponder)
    #expect(view.inputAccessoryView == nil)
  }

  @Test
  func screenModelHostsOneView() {
    let model = TerminalScreenModel()
    model.reset(cols: 64, rows: 20)
    model.feed(Data("\u{1B}[?1049hhello".utf8))
    #expect(model.hasView)
    #expect(model.view.getTerminal().cols == 64)
    #expect(model.view.getTerminal().isCurrentBufferAlternate)
  }
}
