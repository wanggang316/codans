import CodansCore
import Foundation

extension IPC {
  /// Params for `tab.info` — probe a Tab's zmx daemon for the
  /// metadata that backs VT-fidelity assertions (shell pid, working
  /// directory, cursor position, terminal modes). Distinct from
  /// `hierarchy.describeTab`, which reports the catalog's view of the
  /// Tab; this verb round-trips through the daemon so a stale catalog
  /// row does not leak past as live truth.
  public struct TabInfoRequest: Codable, Equatable, Sendable {
    public let contentID: ContentID

    public init(contentID: ContentID) {
      self.contentID = contentID
    }
  }

  /// Cursor position reported by the daemon. Row/col are 0-indexed
  /// against the active screen buffer.
  public struct TabCursor: Codable, Equatable, Sendable {
    public let row: UInt16
    public let col: UInt16

    public init(row: UInt16, col: UInt16) {
      self.row = row
      self.col = col
    }
  }

  /// Result for `tab.info`. `cursor` and `modes` are optional because
  /// the daemon's frozen `Info` payload does not yet carry them —
  /// callers that need byte-faithful cursor/mode assertions should fall
  /// back to `tab.read --raw` and parse the `vt`-format dump, which
  /// includes the cursor and SM/DECSM mode prologue.
  public struct TabInfoResponse: Codable, Equatable, Sendable {
    public let contentID: ContentID
    public let shellPid: Int32
    public let pwd: String
    public let cursor: TabCursor?
    public let modes: [String: Bool]?

    public init(
      contentID: ContentID,
      shellPid: Int32,
      pwd: String,
      cursor: TabCursor? = nil,
      modes: [String: Bool]? = nil
    ) {
      self.contentID = contentID
      self.shellPid = shellPid
      self.pwd = pwd
      self.cursor = cursor
      self.modes = modes
    }
  }
}
