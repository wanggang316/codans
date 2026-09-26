import CodansIPC
import Foundation

/// A key press described the way libghostty's key encoder wants it: Mac
/// virtual keycode, modifiers, the text the key produced and its unshifted
/// codepoint. Built from a remote client's W3C `KeyboardEvent.code`, so a
/// phone key reaches the pane as the same bytes a Mac keypress would —
/// application cursor keys, the Kitty keyboard protocol and all. Pure, so
/// the mapping is table-tested without a surface — and nonisolated, so it
/// is usable off the main actor like any other value type.
nonisolated struct KeyEventSpec: Equatable, Sendable {
  nonisolated struct Mods: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let shift = Mods(rawValue: 1 << 0)
    static let ctrl = Mods(rawValue: 1 << 1)
    static let alt = Mods(rawValue: 1 << 2)
    static let `super` = Mods(rawValue: 1 << 3)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ wire: IPC.TerminalKeyModifiers) {
      var mods: Mods = []
      if wire.shift { mods.insert(.shift) }
      if wire.ctrl { mods.insert(.ctrl) }
      if wire.alt { mods.insert(.alt) }
      if wire.super { mods.insert(.super) }
      self = mods
    }
  }

  /// A keycode libghostty's table does not list, so the key decodes as
  /// "unidentified" and the encoder writes the event's text as-is. `0xFFFF`
  /// would not do: the table uses it for keys a Mac keyboard lacks.
  static let unidentifiedKeycode: UInt32 = 0xFFFE

  let keycode: UInt32
  let mods: Mods
  /// Modifiers spent producing `text`. Shift is, when the key produced
  /// text: otherwise the Kitty encoder would report `A` as shift+a instead
  /// of typing it, where AppKit marks shift consumed for the same press.
  let consumedMods: Mods
  /// What the key typed. Nil for keys that type nothing (Enter, arrows)
  /// and for ctrl / ⌘ chords, which the encoder turns into control
  /// sequences from the keycode instead.
  let text: String?
  /// The key's codepoint with no modifiers applied — what Kitty's CSI-u
  /// encoding and ghostty's binding matching key on.
  let unshiftedCodepoint: UInt32
  /// Set for alt + a printable key. libghostty treats a Mac's Option as a
  /// character-composing key unless `macos-option-as-alt` is on, so the
  /// phone's Alt (Meta) is delivered as ESC + `escPrefixedText` — the
  /// xterm meta convention — rather than as a key event.
  let escPrefixedText: String?

  init(
    keycode: UInt32,
    mods: Mods = [],
    consumedMods: Mods = [],
    text: String? = nil,
    unshiftedCodepoint: UInt32 = 0,
    escPrefixedText: String? = nil
  ) {
    self.keycode = keycode
    self.mods = mods
    self.consumedMods = consumedMods
    self.text = text
    self.unshiftedCodepoint = unshiftedCodepoint
    self.escPrefixedText = escPrefixedText
  }

  /// The spec for one W3C key code, or nil when `code` is not a key this
  /// table knows. `text` is what the sender's layout produced; without
  /// it a printable key types its US-layout character.
  static func key(code: String, text: String?, mods wireMods: IPC.TerminalKeyModifiers) -> KeyEventSpec? {
    guard let entry = table[code] else { return nil }
    let mods = Mods(wireMods)
    let unshifted = entry.base?.unicodeScalars.first?.value ?? 0
    // Keys that type nothing never carry text: the encoder would take an
    // Enter or Escape with text as an IME commit and write the text.
    guard let base = entry.base else {
      return KeyEventSpec(keycode: entry.keycode, mods: mods, unshiftedCodepoint: unshifted)
    }
    let produced: String = {
      if let text, !text.isEmpty, !text.unicodeScalars.contains(where: isControl) { return text }
      if mods.contains(.shift) { return String(entry.shifted ?? base) }
      return String(base)
    }()
    if mods.contains(.ctrl) || mods.contains(.super) {
      return KeyEventSpec(keycode: entry.keycode, mods: mods, unshiftedCodepoint: unshifted)
    }
    let consumed: Mods = mods.contains(.shift) ? [.shift] : []
    let meta = mods.contains(.alt) && produced.utf8.count <= maxEscPrefixedBytes ? produced : nil
    return KeyEventSpec(
      keycode: entry.keycode, mods: mods, consumedMods: consumed, text: produced,
      unshiftedCodepoint: unshifted, escPrefixedText: meta)
  }

  /// Committed text as key events: runs of text become unidentified keys
  /// carrying it — typed, so never wrapped in bracketed paste — and line
  /// breaks and tabs become real Enter and Tab presses so the pane's key
  /// modes shape them. Other control characters are dropped: `text` is
  /// for what a keyboard types, and keys go through `key`.
  static func committedText(_ text: String) -> [KeyEventSpec] {
    var specs: [KeyEventSpec] = []
    var run = ""
    func flush() {
      guard !run.isEmpty else { return }
      specs.append(KeyEventSpec(keycode: unidentifiedKeycode, text: run))
      run = ""
    }
    var previousWasCR = false
    for scalar in text.unicodeScalars {
      defer { previousWasCR = scalar == "\r" }
      switch scalar {
      case "\r":
        flush()
        specs.append(enter)
      case "\n":
        // CR LF is one line break.
        if previousWasCR { continue }
        flush()
        specs.append(enter)
      case "\t":
        flush()
        specs.append(tab)
      case _ where isControl(scalar):
        continue
      default:
        run.unicodeScalars.append(scalar)
      }
    }
    flush()
    return specs
  }

  // MARK: - Table

  private static let enter = KeyEventSpec(keycode: 0x24)
  private static let tab = KeyEventSpec(keycode: 0x30)

  /// Longest text sent through the ESC-prefix path; libghostty formats the
  /// sequence into a small fixed buffer.
  private static let maxEscPrefixedBytes = 32

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
  }

  private nonisolated struct Entry {
    let keycode: UInt32
    /// The US-layout character with no modifiers; nil for keys that type
    /// nothing.
    let base: Character?
    let shifted: Character?

    init(_ keycode: UInt32, _ base: Character? = nil, _ shifted: Character? = nil) {
      self.keycode = keycode
      self.base = base
      self.shifted = shifted
    }
  }

  /// W3C `KeyboardEvent.code` → Mac virtual keycode, from the table
  /// libghostty itself decodes keycodes with (`src/input/keycodes.zig`).
  private static let table: [String: Entry] = {
    var table: [String: Entry] = [:]
    let letters: [(Character, UInt32)] = [
      ("a", 0x00), ("b", 0x0B), ("c", 0x08), ("d", 0x02), ("e", 0x0E), ("f", 0x03), ("g", 0x05),
      ("h", 0x04), ("i", 0x22), ("j", 0x26), ("k", 0x28), ("l", 0x25), ("m", 0x2E), ("n", 0x2D),
      ("o", 0x1F), ("p", 0x23), ("q", 0x0C), ("r", 0x0F), ("s", 0x01), ("t", 0x11), ("u", 0x20),
      ("v", 0x09), ("w", 0x0D), ("x", 0x07), ("y", 0x10), ("z", 0x06),
    ]
    for (letter, keycode) in letters {
      table["Key\(letter.uppercased())"] = Entry(keycode, letter, Character(letter.uppercased()))
    }
    let digits: [(Character, Character, UInt32)] = [
      ("1", "!", 0x12), ("2", "@", 0x13), ("3", "#", 0x14), ("4", "$", 0x15), ("5", "%", 0x17),
      ("6", "^", 0x16), ("7", "&", 0x1A), ("8", "*", 0x1C), ("9", "(", 0x19), ("0", ")", 0x1D),
    ]
    for (digit, shifted, keycode) in digits {
      table["Digit\(digit)"] = Entry(keycode, digit, shifted)
    }
    let printable: [String: Entry] = [
      "Space": Entry(0x31, " ", " "),
      "Minus": Entry(0x1B, "-", "_"),
      "Equal": Entry(0x18, "=", "+"),
      "BracketLeft": Entry(0x21, "[", "{"),
      "BracketRight": Entry(0x1E, "]", "}"),
      "Backslash": Entry(0x2A, "\\", "|"),
      "Semicolon": Entry(0x29, ";", ":"),
      "Quote": Entry(0x27, "'", "\""),
      "Backquote": Entry(0x32, "`", "~"),
      "Comma": Entry(0x2B, ",", "<"),
      "Period": Entry(0x2F, ".", ">"),
      "Slash": Entry(0x2C, "/", "?"),
    ]
    let named: [String: Entry] = [
      "Enter": Entry(0x24), "NumpadEnter": Entry(0x4C), "Escape": Entry(0x35),
      "Backspace": Entry(0x33), "Tab": Entry(0x30), "Delete": Entry(0x75), "Insert": Entry(0x72),
      "Home": Entry(0x73), "End": Entry(0x77), "PageUp": Entry(0x74), "PageDown": Entry(0x79),
      "ArrowUp": Entry(0x7E), "ArrowDown": Entry(0x7D), "ArrowLeft": Entry(0x7B), "ArrowRight": Entry(0x7C),
      "F1": Entry(0x7A), "F2": Entry(0x78), "F3": Entry(0x63), "F4": Entry(0x76), "F5": Entry(0x60),
      "F6": Entry(0x61), "F7": Entry(0x62), "F8": Entry(0x64), "F9": Entry(0x65), "F10": Entry(0x6D),
      "F11": Entry(0x67), "F12": Entry(0x6F),
    ]
    table.merge(printable) { current, _ in current }
    table.merge(named) { current, _ in current }
    return table
  }()
}
