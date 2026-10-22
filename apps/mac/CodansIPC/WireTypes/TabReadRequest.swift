import CodansCore
import Foundation

extension IPC {
  /// Selects which slice of the daemon's terminal mirror `tab.read`
  /// returns. The daemon today serializes the entire terminal (scrollback
  /// + visible region) in one shot; `visible` and `scrollback` are
  /// filtered client-side after the daemon returns its full dump.
  public enum TabReadRange: String, Codable, Sendable {
    /// Active viewport only — what the user currently sees on screen.
    case visible
    /// Scrolled-off rows above the viewport.
    case scrollback
    /// Scrollback + visible viewport. The default.
    case all
  }

  /// Params for `tab.read` — pull serialized terminal state straight
  /// from the Tab's zmx daemon. Unlike `terminal.readText`, which
  /// reads libghostty's parsed-text surface, this verb returns the
  /// daemon's `serializeTerminalState` output so callers can assert on
  /// the original ANSI byte stream (cursor, SGR, OSC, DECSM, etc.).
  public struct TabReadRequest: Codable, Equatable, Sendable {
    public let contentID: ContentID
    public let range: TabReadRange
    /// Return only the last N newline-delimited lines. Applied after
    /// the daemon's dump arrives and after `range` filtering.
    public let tail: Int?
    /// `true` requests the `vt`-format dump (ANSI escapes preserved).
    /// `false` requests the `plain`-format dump (escapes stripped).
    public let raw: Bool

    public init(
      contentID: ContentID,
      range: TabReadRange = .all,
      tail: Int? = nil,
      raw: Bool = false
    ) {
      self.contentID = contentID
      self.range = range
      self.tail = tail
      self.raw = raw
    }
  }

  /// Result for `tab.read`. `content` is the (possibly trimmed)
  /// serialized terminal state. `format` records whether `content`
  /// carries ANSI escapes (`vt`) or stripped text (`plain`).
  public struct TabReadResponse: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
      case plain
      case vt
    }

    public let contentID: ContentID
    public let format: Format
    public let content: String

    public init(contentID: ContentID, format: Format, content: String) {
      self.contentID = contentID
      self.format = format
      self.content = content
    }
  }
}
