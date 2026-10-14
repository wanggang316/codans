import CodansIPC
import Foundation

/// Encodes key events into the bytes a terminal expects, the way xterm
/// (and ghostty's legacy encoding) does, for typing through a terminal
/// seat: the device then talks to the pane's session directly instead of
/// through the Mac's surface.
///
/// The pane's modes come from this device's own emulator, which receives
/// the same bytes as the Mac: application cursor keys (DECCKM) and
/// bracketed paste. The kitty keyboard protocol is not spoken; programs
/// that ask for it still accept these legacy sequences.
nonisolated enum TerminalKeyEncoder {
  struct Modes: Equatable, Sendable {
    var applicationCursor = false
    var bracketedPaste = false
  }

  /// One step of an encoded batch: bytes to type, or a pause.
  enum Chunk: Equatable, Sendable {
    case bytes(Data)
    case delay(millis: Int)
  }

  /// A batch as bytes, adjacent bytes merged, pauses kept in order. Events
  /// with no terminal encoding (⌘ chords, unknown keys) are dropped and
  /// counted in `dropped`.
  static func encode(_ events: [IPC.TerminalInputEvent], modes: Modes) -> (chunks: [Chunk], dropped: Int) {
    var chunks: [Chunk] = []
    var pending = Data()
    var dropped = 0
    func flush() {
      if !pending.isEmpty { chunks.append(.bytes(pending)) }
      pending = Data()
    }
    for event in events {
      switch event {
      case .delay(let millis):
        flush()
        chunks.append(.delay(millis: millis))
      default:
        if let bytes = encode(event, modes: modes) {
          pending.append(bytes)
        } else {
          dropped += 1
        }
      }
    }
    flush()
    return (chunks, dropped)
  }

  static func encode(_ event: IPC.TerminalInputEvent, modes: Modes) -> Data? {
    switch event {
    case .text(let text):
      return Data(text.utf8)
    case .paste(let text):
      guard modes.bracketedPaste else { return Data(text.utf8) }
      // A paste that contains the end marker would end the paste early.
      let body = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
      return Data(("\u{1B}[200~" + body + "\u{1B}[201~").utf8)
    case .key(let code, let text, let mods):
      return key(code, text: text, mods: mods, modes: modes)
    case .delay, .unknown:
      return nil
    }
  }

  // MARK: - Keys

  private static let esc = "\u{1B}"

  private static func key(
    _ code: String, text: String?, mods: IPC.TerminalKeyModifiers, modes: Modes
  ) -> Data? {
    // ⌘ chords are the device's own shortcuts, never terminal input.
    guard !mods.super else { return nil }
    if let sequence = named(code, mods: mods, modes: modes) { return Data(sequence.utf8) }
    guard let character = text.flatMap(\.first) ?? TerminalKeyMap.character(for: code, shift: mods.shift) else {
      return nil
    }
    var bytes: [UInt8]
    if mods.ctrl, let control = controlByte(for: character) {
      bytes = [control]
    } else {
      bytes = Array(String(character).utf8)
    }
    if mods.alt { bytes.insert(0x1B, at: 0) }
    return Data(bytes)
  }

  /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
  private static func modifierParameter(_ mods: IPC.TerminalKeyModifiers) -> Int {
    1 + (mods.shift ? 1 : 0) + (mods.alt ? 2 : 0) + (mods.ctrl ? 4 : 0)
  }

  private static func named(_ code: String, mods: IPC.TerminalKeyModifiers, modes: Modes) -> String? {
    let parameter = modifierParameter(mods)
    let modified = parameter > 1
    let altPrefix = mods.alt ? esc : ""
    switch code {
    case "Enter", "NumpadEnter":
      return altPrefix + "\r"
    case "Tab":
      return mods.shift ? esc + "[Z" : altPrefix + "\t"
    case "Escape":
      return altPrefix + esc
    case "Backspace":
      return altPrefix + (mods.ctrl ? "\u{08}" : "\u{7F}")
    case "Space" where mods.ctrl:
      return altPrefix + "\u{00}"
    case "ArrowUp", "ArrowDown", "ArrowRight", "ArrowLeft", "Home", "End":
      let final: String = [
        "ArrowUp": "A", "ArrowDown": "B", "ArrowRight": "C", "ArrowLeft": "D", "Home": "H", "End": "F",
      ][code]!
      if modified { return esc + "[1;\(parameter)" + final }
      return esc + (modes.applicationCursor ? "O" : "[") + final
    case "Insert", "Delete", "PageUp", "PageDown":
      let number = ["Insert": 2, "Delete": 3, "PageUp": 5, "PageDown": 6][code]!
      return esc + "[\(number)" + (modified ? ";\(parameter)" : "") + "~"
    case "F1", "F2", "F3", "F4":
      let final = ["F1": "P", "F2": "Q", "F3": "R", "F4": "S"][code]!
      return modified ? esc + "[1;\(parameter)" + final : esc + "O" + final
    case "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12":
      let number = ["F5": 15, "F6": 17, "F7": 18, "F8": 19, "F9": 20, "F10": 21, "F11": 23, "F12": 24][code]!
      return esc + "[\(number)" + (modified ? ";\(parameter)" : "") + "~"
    default:
      return nil
    }
  }

  /// The C0 control a Ctrl chord types: Ctrl-A … Ctrl-Z are 1…26, and
  /// the punctuation xterm maps (`[` ESC, `\` FS, `]` GS, `^` RS, `_` US,
  /// `@` / `2` NUL, `?` DEL).
  private static func controlByte(for character: Character) -> UInt8? {
    guard let ascii = character.asciiValue else { return nil }
    switch ascii {
    case UInt8(ascii: "a")...UInt8(ascii: "z"): return ascii - UInt8(ascii: "a") + 1
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): return ascii - UInt8(ascii: "A") + 1
    case UInt8(ascii: "@"), UInt8(ascii: "2"), UInt8(ascii: " "): return 0
    case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
    case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
    case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
    case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
    case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"): return 0x1F
    case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
    default: return nil
    }
  }
}
