import CodansCore
import GhosttyKit
import Testing

@testable import Codans
@testable import CodansIPC

/// Table tests for the W3C code → libghostty key event mapping behind
/// `terminal.sendEvents`.
struct KeyEventSpecTests {
  private typealias Mods = IPC.TerminalKeyModifiers

  struct Case: Sendable, CustomTestStringConvertible {
    let code: String
    let text: String?
    let mods: IPC.TerminalKeyModifiers
    let keycode: UInt32
    let expectedText: String?
    let unshifted: UInt32
    let consumesShift: Bool
    var testDescription: String { "\(code) \(mods)" }
  }

  static let cases: [Case] = [
    // Printable keys type their US-layout character.
    Case(code: "KeyA", text: nil, mods: .none, keycode: 0x00, expectedText: "a", unshifted: 0x61, consumesShift: false),
    Case(
      code: "KeyA", text: nil, mods: Mods(shift: true), keycode: 0x00, expectedText: "A", unshifted: 0x61,
      consumesShift: true),
    Case(
      code: "Digit2", text: nil, mods: Mods(shift: true), keycode: 0x13, expectedText: "@", unshifted: 0x32,
      consumesShift: true),
    Case(code: "Slash", text: nil, mods: .none, keycode: 0x2C, expectedText: "/", unshifted: 0x2F, consumesShift: false),
    Case(code: "Space", text: nil, mods: .none, keycode: 0x31, expectedText: " ", unshifted: 0x20, consumesShift: false),
    // The sender's layout wins over the table.
    Case(code: "KeyQ", text: "a", mods: .none, keycode: 0x0C, expectedText: "a", unshifted: 0x71, consumesShift: false),
    // Ctrl / ⌘ chords carry no text; the encoder works from the keycode.
    Case(code: "KeyC", text: "c", mods: Mods(ctrl: true), keycode: 0x08, expectedText: nil, unshifted: 0x63, consumesShift: false),
    Case(code: "KeyV", text: nil, mods: Mods(super: true), keycode: 0x09, expectedText: nil, unshifted: 0x76, consumesShift: false),
    Case(
      code: "KeyR", text: nil, mods: Mods(ctrl: true, shift: true), keycode: 0x0F, expectedText: nil, unshifted: 0x72,
      consumesShift: false),
    // Keys that type nothing never carry text, even when sent with some.
    Case(code: "Enter", text: "\r", mods: .none, keycode: 0x24, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "Escape", text: nil, mods: .none, keycode: 0x35, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "Tab", text: nil, mods: Mods(shift: true), keycode: 0x30, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "Backspace", text: nil, mods: .none, keycode: 0x33, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "ArrowUp", text: nil, mods: .none, keycode: 0x7E, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "ArrowLeft", text: nil, mods: Mods(alt: true), keycode: 0x7B, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "PageDown", text: nil, mods: .none, keycode: 0x79, expectedText: nil, unshifted: 0, consumesShift: false),
    Case(code: "F12", text: nil, mods: .none, keycode: 0x6F, expectedText: nil, unshifted: 0, consumesShift: false),
  ]

  @Test(arguments: cases)
  func mapsCodeToGhosttyKey(_ testCase: Case) throws {
    let spec = try #require(KeyEventSpec.key(code: testCase.code, text: testCase.text, mods: testCase.mods))
    #expect(spec.keycode == testCase.keycode)
    #expect(spec.text == testCase.expectedText)
    #expect(spec.unshiftedCodepoint == testCase.unshifted)
    #expect(spec.consumedMods == (testCase.consumesShift ? [.shift] : []))
    #expect(spec.mods == KeyEventSpec.Mods(testCase.mods))
    #expect(spec.escPrefixedText == nil)
  }

  @Test
  func unknownCodesAreRefused() {
    #expect(KeyEventSpec.key(code: "MediaPlayPause", text: nil, mods: .none) == nil)
    #expect(KeyEventSpec.key(code: "keya", text: nil, mods: .none) == nil)
  }

  @Test
  func altOnAPrintableKeyIsMeta() throws {
    let altB = try #require(KeyEventSpec.key(code: "KeyB", text: nil, mods: Mods(alt: true)))
    #expect(altB.escPrefixedText == "b")
    let altShiftDot = try #require(KeyEventSpec.key(code: "Period", text: nil, mods: Mods(alt: true, shift: true)))
    #expect(altShiftDot.escPrefixedText == ">")
    // Ctrl+Alt stays a key event: the encoder ESC-prefixes the control byte.
    let ctrlAlt = try #require(KeyEventSpec.key(code: "KeyX", text: nil, mods: Mods(ctrl: true, alt: true)))
    #expect(ctrlAlt.escPrefixedText == nil)
    #expect(ctrlAlt.text == nil)
  }

  @Test
  func committedTextBecomesTypedRunsAndRealKeys() {
    let unidentified = KeyEventSpec.unidentifiedKeycode
    #expect(
      KeyEventSpec.committedText("echo 你好\r\nls\tx")
        == [
          KeyEventSpec(keycode: unidentified, text: "echo 你好"),
          KeyEventSpec(keycode: 0x24),
          KeyEventSpec(keycode: unidentified, text: "ls"),
          KeyEventSpec(keycode: 0x30),
          KeyEventSpec(keycode: unidentified, text: "x"),
        ])
    #expect(KeyEventSpec.committedText("a\nb\rc").map(\.keycode) == [unidentified, 0x24, unidentified, 0x24, unidentified])
    #expect(KeyEventSpec.committedText("a\u{1B}[31mb") == [KeyEventSpec(keycode: unidentified, text: "a[31mb")])
    #expect(KeyEventSpec.committedText("").isEmpty)
  }
}

/// The binding filter behind `terminal.sendEvents`: only ⌘ bindings are
/// refused outright, other bindings run guarded, and the guard swallows
/// only actions that would drive the Mac's app, windows, tabs or splits.
@MainActor
struct RemoteKeyBindingTests {
  @Test
  func onlySuperBindingsAreRefusedUpFront() {
    #expect(RemoteKeyBinding.decide(isBinding: false, mods: [.super]) == .encode)
    #expect(RemoteKeyBinding.decide(isBinding: false, mods: []) == .encode)
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: [.super]) == .reject)
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: [.super, .shift]) == .reject)
    // alt+← (esc:b), ctrl+tab (next tab), shift+← (adjust selection).
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: [.alt]) == .performGuarded)
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: [.ctrl]) == .performGuarded)
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: [.shift]) == .performGuarded)
    #expect(RemoteKeyBinding.decide(isBinding: true, mods: []) == .performGuarded)
  }

  @Test
  func guardSwallowsChromeActionsForItsPane() {
    let pane = PaneID()
    let keyGuard = RemoteKeyGuard(paneID: pane)
    #expect(!keyGuard.shouldSuppress(GHOSTTY_ACTION_RENDER, surfacePaneID: pane))
    #expect(!keyGuard.shouldSuppress(GHOSTTY_ACTION_SET_TITLE, surfacePaneID: pane))
    #expect(!keyGuard.shouldSuppress(GHOSTTY_ACTION_MOUSE_VISIBILITY, surfacePaneID: pane))
    #expect(!keyGuard.suppressed)
    // Another pane's surface action is not this key's doing.
    #expect(!keyGuard.shouldSuppress(GHOSTTY_ACTION_GOTO_TAB, surfacePaneID: PaneID()))
    #expect(!keyGuard.suppressed)
    #expect(keyGuard.shouldSuppress(GHOSTTY_ACTION_GOTO_TAB, surfacePaneID: pane))
    #expect(keyGuard.suppressed)
  }

  @Test
  func guardSwallowsAppActionsAndClipboardReads() {
    let pane = PaneID()
    let appAction = RemoteKeyGuard(paneID: pane)
    #expect(appAction.shouldSuppress(GHOSTTY_ACTION_QUIT, surfacePaneID: nil))
    #expect(appAction.suppressed)

    let clipboard = RemoteKeyGuard(paneID: pane)
    #expect(!clipboard.shouldRefuseClipboardRead(for: PaneID()))
    #expect(!clipboard.suppressed)
    #expect(clipboard.shouldRefuseClipboardRead(for: pane))
    #expect(clipboard.suppressed)
  }

  @Test(arguments: [
    GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_GOTO_TAB, GHOSTTY_ACTION_NEW_SPLIT,
    GHOSTTY_ACTION_GOTO_SPLIT, GHOSTTY_ACTION_RESIZE_SPLIT, GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
    GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_TOGGLE_FULLSCREEN, GHOSTTY_ACTION_START_SEARCH,
    GHOSTTY_ACTION_INSPECTOR, GHOSTTY_ACTION_OPEN_CONFIG, GHOSTTY_ACTION_QUIT,
  ])
  func chromeActionsDoNotPassTheGuard(_ tag: ghostty_action_tag_e) {
    #expect(!RemoteKeyBinding.passesGuard(tag))
  }
}
