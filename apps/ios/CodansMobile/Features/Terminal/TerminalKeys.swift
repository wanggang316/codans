import CodansCore
import CodansIPC
import Foundation
import UIKit

/// The key bar's Ctrl and Alt: a tap arms the modifier for the next key
/// only, a second tap within `lockWindow` locks it until tapped again, and
/// a later second tap on an armed modifier disarms it.
nonisolated struct ModifierLatch: Equatable, Sendable {
  enum Modifier: String, CaseIterable, Equatable, Sendable {
    case ctrl
    case alt
  }

  enum Mode: Equatable, Sendable {
    case off
    case armed
    case locked
  }

  static let lockWindow: TimeInterval = 0.4

  private(set) var ctrl: Mode = .off
  private(set) var alt: Mode = .off
  private var lastTap: [Modifier: Date] = [:]

  func mode(_ modifier: Modifier) -> Mode {
    switch modifier {
    case .ctrl: return ctrl
    case .alt: return alt
    }
  }

  mutating func tap(_ modifier: Modifier, at now: Date) {
    let previous = lastTap[modifier]
    lastTap[modifier] = now
    let next: Mode
    switch mode(modifier) {
    case .off:
      next = .armed
    case .armed:
      let isDoubleTap = previous.map { now.timeIntervalSince($0) <= Self.lockWindow } ?? false
      next = isDoubleTap ? .locked : .off
    case .locked:
      next = .off
    }
    set(modifier, next)
  }

  /// The modifiers the next key carries.
  var modifiers: IPC.TerminalKeyModifiers {
    IPC.TerminalKeyModifiers(ctrl: ctrl != .off, alt: alt != .off)
  }

  var isActive: Bool { ctrl != .off || alt != .off }

  /// A key used the modifiers: one-shot ones go back to off.
  mutating func consume() {
    if ctrl == .armed { ctrl = .off }
    if alt == .armed { alt = .off }
  }

  mutating func clear() {
    self = ModifierLatch()
  }

  private mutating func set(_ modifier: Modifier, _ mode: Mode) {
    switch modifier {
    case .ctrl: ctrl = mode
    case .alt: alt = mode
    }
  }
}

/// W3C `KeyboardEvent.code` vocabulary for what the phone types, on a US
/// layout — the same table the Mac encodes from.
nonisolated enum TerminalKeyMap {
  /// A typed character as the key that types it: `A` is `KeyA` with
  /// shift, `~` is `Backquote` with shift. Nil for characters no US key
  /// types (they go as committed text).
  static func key(for character: Character) -> (code: String, shift: Bool)? {
    if let entry = characterTable[character] { return entry }
    return nil
  }

  /// A key event for a character typed while modifiers are latched.
  /// Ctrl and Alt chords carry no text: the Mac encodes them from the key.
  static func event(for character: Character, mods: IPC.TerminalKeyModifiers) -> IPC.TerminalInputEvent? {
    guard let key = key(for: character) else { return nil }
    var mods = mods
    if key.shift { mods.shift = true }
    return .key(code: key.code, text: nil, mods: mods)
  }

  /// A hardware key's W3C code from its HID usage.
  static func code(for usage: UIKeyboardHIDUsage) -> String? {
    hidTable[usage.rawValue]
  }

  /// Keys that type nothing: the input view handles them itself instead
  /// of leaving them to the text system.
  static func isNonTextKey(_ code: String) -> Bool {
    nonTextCodes.contains(code)
  }

  /// Keys a held hardware key repeats.
  static func repeats(_ code: String) -> Bool {
    ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Backspace", "Delete"].contains(code)
  }

  static func modifiers(_ flags: UIKeyModifierFlags) -> IPC.TerminalKeyModifiers {
    IPC.TerminalKeyModifiers(
      ctrl: flags.contains(.control), alt: flags.contains(.alternate), shift: flags.contains(.shift),
      super: flags.contains(.command))
  }

  private static let nonTextCodes: Set<String> = [
    "Enter", "NumpadEnter", "Escape", "Backspace", "Tab", "Delete", "Insert", "Home", "End", "PageUp",
    "PageDown", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
  ]

  private static let characterTable: [Character: (code: String, shift: Bool)] = {
    var table: [Character: (code: String, shift: Bool)] = [:]
    for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
      let lower = Character(UnicodeScalar(scalar)!)
      let code = "Key\(lower.uppercased())"
      table[lower] = (code, false)
      table[Character(lower.uppercased())] = (code, true)
    }
    let digits: [(Character, Character)] = [
      ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"),
      ("6", "^"), ("7", "&"), ("8", "*"), ("9", "("), ("0", ")"),
    ]
    for (digit, shifted) in digits {
      table[digit] = ("Digit\(digit)", false)
      table[shifted] = ("Digit\(digit)", true)
    }
    let punctuation: [(String, Character, Character)] = [
      ("Space", " ", " "), ("Minus", "-", "_"), ("Equal", "=", "+"), ("BracketLeft", "[", "{"),
      ("BracketRight", "]", "}"), ("Backslash", "\\", "|"), ("Semicolon", ";", ":"), ("Quote", "'", "\""),
      ("Backquote", "`", "~"), ("Comma", ",", "<"), ("Period", ".", ">"), ("Slash", "/", "?"),
    ]
    for (code, base, shifted) in punctuation {
      table[base] = (code, false)
      if shifted != base { table[shifted] = (code, true) }
    }
    return table
  }()

  private static let hidTable: [Int: String] = {
    var table: [Int: String] = [:]
    // keyboardA (0x04) … keyboardZ (0x1D)
    for offset in 0..<26 {
      table[0x04 + offset] = "Key\(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(offset))))"
    }
    // keyboard1 (0x1E) … keyboard9 (0x26), keyboard0 (0x27)
    for offset in 0..<9 { table[0x1E + offset] = "Digit\(offset + 1)" }
    table[0x27] = "Digit0"
    // keyboardF1 (0x3A) … keyboardF12 (0x45)
    for offset in 0..<12 { table[0x3A + offset] = "F\(offset + 1)" }
    let named: [UIKeyboardHIDUsage: String] = [
      .keyboardReturnOrEnter: "Enter", .keyboardEscape: "Escape", .keyboardDeleteOrBackspace: "Backspace",
      .keyboardTab: "Tab", .keyboardSpacebar: "Space", .keyboardHyphen: "Minus", .keyboardEqualSign: "Equal",
      .keyboardOpenBracket: "BracketLeft", .keyboardCloseBracket: "BracketRight", .keyboardBackslash: "Backslash",
      .keyboardSemicolon: "Semicolon", .keyboardQuote: "Quote", .keyboardGraveAccentAndTilde: "Backquote",
      .keyboardComma: "Comma", .keyboardPeriod: "Period", .keyboardSlash: "Slash", .keyboardInsert: "Insert",
      .keyboardHome: "Home", .keyboardPageUp: "PageUp", .keyboardDeleteForward: "Delete", .keyboardEnd: "End",
      .keyboardPageDown: "PageDown", .keyboardRightArrow: "ArrowRight", .keyboardLeftArrow: "ArrowLeft",
      .keyboardDownArrow: "ArrowDown", .keyboardUpArrow: "ArrowUp", .keypadEnter: "NumpadEnter",
    ]
    for (usage, code) in named { table[usage.rawValue] = code }
    return table
  }()
}

/// Events for a named key with no modifiers.
nonisolated extension IPC.TerminalInputEvent {
  static func press(_ code: String, _ mods: IPC.TerminalKeyModifiers = .none) -> Self {
    .key(code: code, text: nil, mods: mods)
  }

  static func ctrl(_ letter: Character) -> Self {
    .key(code: "Key\(letter.uppercased())", text: nil, mods: IPC.TerminalKeyModifiers(ctrl: true))
  }

  /// A slash command typed and submitted.
  static func command(_ text: String) -> [Self] {
    [.text(text), .press("Enter")]
  }
}

/// One entry of the Ctrl long-press panel.
nonisolated struct TerminalShortcut: Equatable, Identifiable, Sendable {
  let title: String
  let detail: String
  let events: [IPC.TerminalInputEvent]

  var id: String { title }
}

/// The Ctrl long-press panel's pages. The panel opens on the page for the
/// pane's agent, so an agent's commands are one gesture away.
nonisolated enum TerminalShortcutPage: String, CaseIterable, Equatable, Identifiable, Sendable {
  case claudeCode
  case codex
  case tmux
  case control

  var id: String { rawValue }

  static func defaultPage(forAgent agent: String?) -> Self {
    switch agent.flatMap(AgentKind.init(rawValue:)) {
    case .claudeCode?: return .claudeCode
    case .codex?: return .codex
    default: return .control
    }
  }

  var title: String {
    switch self {
    case .claudeCode: return "Claude"
    case .codex: return "Codex"
    case .tmux: return "tmux"
    case .control: return "Ctrl"
    }
  }

  var shortcuts: [TerminalShortcut] {
    switch self {
    case .claudeCode:
      return [
        TerminalShortcut(title: "/clear", detail: "New conversation", events: IPC.TerminalInputEvent.command("/clear")),
        TerminalShortcut(
          title: "/compact", detail: "Summarize context", events: IPC.TerminalInputEvent.command("/compact")),
        TerminalShortcut(title: "/resume", detail: "Pick a session", events: IPC.TerminalInputEvent.command("/resume")),
        TerminalShortcut(title: "/help", detail: "Commands", events: IPC.TerminalInputEvent.command("/help")),
        TerminalShortcut(
          title: "⇧Tab", detail: "Cycle mode", events: [.press("Tab", IPC.TerminalKeyModifiers(shift: true))]),
        TerminalShortcut(title: "Esc Esc", detail: "Rewind", events: [.press("Escape"), .press("Escape")]),
      ]
    case .codex:
      return [
        TerminalShortcut(title: "/new", detail: "New conversation", events: IPC.TerminalInputEvent.command("/new")),
        TerminalShortcut(
          title: "/compact", detail: "Summarize context", events: IPC.TerminalInputEvent.command("/compact")),
        TerminalShortcut(title: "/model", detail: "Switch model", events: IPC.TerminalInputEvent.command("/model")),
        TerminalShortcut(
          title: "/approvals", detail: "Approval mode", events: IPC.TerminalInputEvent.command("/approvals")),
        TerminalShortcut(title: "/diff", detail: "Show changes", events: IPC.TerminalInputEvent.command("/diff")),
        TerminalShortcut(title: "Esc", detail: "Interrupt", events: [.press("Escape")]),
      ]
    case .tmux:
      let prefix = IPC.TerminalInputEvent.ctrl("b")
      func item(_ title: String, _ detail: String, _ character: Character) -> TerminalShortcut {
        let key = TerminalKeyMap.event(for: character, mods: .none) ?? .text(String(character))
        return TerminalShortcut(title: title, detail: detail, events: [prefix, key])
      }
      return [
        item("⌃B c", "New window", "c"),
        item("⌃B n", "Next window", "n"),
        item("⌃B p", "Previous window", "p"),
        item("⌃B %", "Split side by side", "%"),
        item("⌃B \"", "Split stacked", "\""),
        item("⌃B o", "Next pane", "o"),
        item("⌃B z", "Zoom pane", "z"),
        item("⌃B [", "Scroll mode", "["),
        item("⌃B d", "Detach", "d"),
      ]
    case .control:
      let letters: [(Character, String)] = [
        ("c", "Interrupt"), ("d", "End of input"), ("z", "Suspend"), ("l", "Clear screen"),
        ("a", "Line start"), ("e", "Line end"), ("r", "Search history"), ("w", "Delete word"),
      ]
      return letters.map { letter, detail in
        TerminalShortcut(title: "⌃\(letter.uppercased())", detail: detail, events: [.ctrl(letter)])
      }
    }
  }
}

/// The compose card's recent entries: newest first, no duplicates, at most
/// `limit`.
nonisolated struct ComposeHistory: Equatable, Sendable {
  static let limit = 20

  private(set) var entries: [String]

  init(entries: [String] = []) {
    self.entries = Array(entries.prefix(Self.limit))
  }

  mutating func record(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    entries.removeAll { $0 == text }
    entries.insert(text, at: 0)
    if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
  }
}
