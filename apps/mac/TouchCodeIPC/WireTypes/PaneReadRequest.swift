import Foundation
import TouchCodeCore

extension IPC {
  /// Selects which slice of the daemon's terminal mirror `pane.read`
  /// returns. The daemon today serializes the entire terminal (scrollback
  /// + visible region) in one shot; `visible` and `scrollback` are
  /// filtered client-side after the daemon returns its full dump.
  public enum PaneReadRange: String, Codable, Sendable {
    /// Active viewport only — what the user currently sees on screen.
    case visible
    /// Scrolled-off rows above the viewport.
    case scrollback
    /// Scrollback + visible viewport. The default.
    case all
  }

  /// Params for `pane.read` — pull serialized terminal state straight
  /// from the pane's zmx daemon. Unlike `terminal.readText`, which
  /// reads libghostty's parsed-text surface, this verb returns the
  /// daemon's `serializeTerminalState` output so callers can assert on
  /// the original ANSI byte stream (cursor, SGR, OSC, DECSM, etc.).
  public struct PaneReadRequest: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let range: PaneReadRange
    /// Return only the last N newline-delimited lines. Applied after
    /// the daemon's dump arrives and after `range` filtering.
    public let tail: Int?
    /// `true` requests the `vt`-format dump (ANSI escapes preserved).
    /// `false` requests the `plain`-format dump (escapes stripped).
    public let raw: Bool

    public init(
      paneID: PaneID,
      range: PaneReadRange = .all,
      tail: Int? = nil,
      raw: Bool = false
    ) {
      self.paneID = paneID
      self.range = range
      self.tail = tail
      self.raw = raw
    }
  }

  /// Result for `pane.read`. `content` is the (possibly trimmed)
  /// serialized terminal state. `format` records whether `content`
  /// carries ANSI escapes (`vt`) or stripped text (`plain`).
  public struct PaneReadResponse: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
      case plain
      case vt
    }

    public let paneID: PaneID
    public let format: Format
    public let content: String

    public init(paneID: PaneID, format: Format, content: String) {
      self.paneID = paneID
      self.format = format
      self.content = content
    }
  }
}
