import CodansCore
import Foundation

extension IPC {
  /// Modifier keys held with a `TerminalInputEvent.key`. Every field is
  /// optional on the wire; a missing one means "not held".
  public struct TerminalKeyModifiers: Codable, Equatable, Hashable, Sendable {
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    /// ⌘ on a Mac keyboard, the Windows / Super key elsewhere.
    public var `super`: Bool

    public init(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, super: Bool = false) {
      self.ctrl = ctrl
      self.alt = alt
      self.shift = shift
      self.super = `super`
    }

    public static let none = TerminalKeyModifiers()

    private enum CodingKeys: String, CodingKey {
      case ctrl, alt, shift, `super`
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      ctrl = try c.decodeIfPresent(Bool.self, forKey: .ctrl) ?? false
      alt = try c.decodeIfPresent(Bool.self, forKey: .alt) ?? false
      shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
      `super` = try c.decodeIfPresent(Bool.self, forKey: .super) ?? false
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      if ctrl { try c.encode(true, forKey: .ctrl) }
      if alt { try c.encode(true, forKey: .alt) }
      if shift { try c.encode(true, forKey: .shift) }
      if `super` { try c.encode(true, forKey: .super) }
    }
  }

  /// One entry of a `terminal.sendEvents` batch. Flat on the wire,
  /// discriminated by `kind`:
  ///
  /// - `{"kind": "key", "code": "KeyC", "mods": {"ctrl": true}}`
  /// - `{"kind": "text", "text": "ls"}`
  /// - `{"kind": "paste", "text": "…"}`
  /// - `{"kind": "delay", "ms": 30}`
  public enum TerminalInputEvent: Codable, Equatable, Sendable {
    /// A key as a keyboard would press it. `code` is a W3C
    /// `KeyboardEvent.code` (`KeyC`, `ArrowUp`, `Enter`); `text` is what
    /// the key produced on the sender's layout, when it produced any.
    case key(code: String, text: String?, mods: TerminalKeyModifiers)
    /// Committed text — IME output, dictation, typed characters. Typed,
    /// not pasted: it is never wrapped in bracketed-paste markers.
    case text(String)
    /// Text delivered through the pane's paste path, so a program with
    /// bracketed paste on takes it as one insertion.
    case paste(String)
    /// Pause before the next event, so a TUI can settle between a paste
    /// and its Enter.
    case delay(millis: Int)
    /// A kind this build does not know, from a newer client. The server
    /// rejects just this entry instead of failing the batch.
    case unknown(kind: String)

    /// Largest `paste` or `text` payload, in UTF-8 bytes.
    public static let maxTextBytes = 64 * 1024
    /// Longest single `delay`.
    public static let maxDelayMillis = 500

    public var kind: String {
      switch self {
      case .key: return "key"
      case .text: return "text"
      case .paste: return "paste"
      case .delay: return "delay"
      case .unknown(let kind): return kind
      }
    }

    private enum CodingKeys: String, CodingKey {
      case kind, code, text, mods, ms
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let kind = try c.decode(String.self, forKey: .kind)
      switch kind {
      case "key":
        self = .key(
          code: try c.decode(String.self, forKey: .code),
          text: try c.decodeIfPresent(String.self, forKey: .text),
          mods: try c.decodeIfPresent(TerminalKeyModifiers.self, forKey: .mods) ?? .none)
      case "text":
        self = .text(try c.decode(String.self, forKey: .text))
      case "paste":
        self = .paste(try c.decode(String.self, forKey: .text))
      case "delay":
        self = .delay(millis: try c.decode(Int.self, forKey: .ms))
      default:
        self = .unknown(kind: kind)
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(kind, forKey: .kind)
      switch self {
      case .key(let code, let text, let mods):
        try c.encode(code, forKey: .code)
        try c.encodeIfPresent(text, forKey: .text)
        if mods != .none { try c.encode(mods, forKey: .mods) }
      case .text(let text), .paste(let text):
        try c.encode(text, forKey: .text)
      case .delay(let millis):
        try c.encode(millis, forKey: .ms)
      case .unknown:
        break
      }
    }
  }

  /// `terminal.sendEvents` params: an ordered batch for one pane.
  public struct TerminalSendEventsRequest: Codable, Equatable, Sendable {
    /// Most events one call may carry.
    public static let maxEvents = 256
    /// Most total `delay` one call may spend, so a batch cannot hold its
    /// connection for long.
    public static let maxTotalDelayMillis = 2000

    public let paneID: PaneID
    public let events: [TerminalInputEvent]

    public init(paneID: PaneID, events: [TerminalInputEvent]) {
      self.paneID = paneID
      self.events = events
    }
  }

  /// Why one event of a batch was not delivered. The rest of the batch
  /// still runs.
  public struct TerminalInputRejection: Codable, Equatable, Sendable {
    /// Well-known `reason` values. A plain string on the wire so a newer
    /// server's reason still decodes.
    public enum Reason {
      /// The key is one of the Mac app's own shortcuts (⌘V, ⌘W, …).
      public static let binding = "binding"
      /// `code` is not a key this build can encode.
      public static let unknownKey = "unknownKey"
      /// An event kind this build does not know.
      public static let unknownEvent = "unknownEvent"
      /// `text` / `paste` over `TerminalInputEvent.maxTextBytes`.
      public static let tooLarge = "tooLarge"
      /// A negative delay, one over `maxDelayMillis`, or one past the
      /// batch's total delay budget.
      public static let outOfRange = "outOfRange"
      /// The pane's surface closed partway through the batch.
      public static let paneGone = "paneGone"
    }

    public let index: Int
    public let reason: String

    public init(index: Int, reason: String) {
      self.index = index
      self.reason = reason
    }
  }

  /// `terminal.sendEvents` result. `delivered` counts the events applied,
  /// delays included; every other event is listed in `rejected`.
  public struct TerminalSendEventsResult: Codable, Equatable, Sendable {
    public let delivered: Int
    public let rejected: [TerminalInputRejection]

    public init(delivered: Int, rejected: [TerminalInputRejection]) {
      self.delivered = delivered
      self.rejected = rejected
    }
  }
}
