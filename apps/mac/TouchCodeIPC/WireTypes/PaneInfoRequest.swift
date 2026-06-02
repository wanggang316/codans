import Foundation
import TouchCodeCore

extension IPC {
  /// Params for `pane.info` — probe a pane's zmx daemon for the
  /// metadata that backs VT-fidelity assertions (shell pid, working
  /// directory, cursor position, terminal modes). Distinct from
  /// `hierarchy.describePane`, which reports the catalog's view of the
  /// pane; this verb round-trips through the daemon so a stale catalog
  /// row does not leak past as live truth.
  public struct PaneInfoRequest: Codable, Equatable, Sendable {
    public let paneID: PaneID

    public init(paneID: PaneID) {
      self.paneID = paneID
    }
  }

  /// Cursor position reported by the daemon. Row/col are 0-indexed
  /// against the active screen buffer.
  public struct PaneCursor: Codable, Equatable, Sendable {
    public let row: UInt16
    public let col: UInt16

    public init(row: UInt16, col: UInt16) {
      self.row = row
      self.col = col
    }
  }

  /// Result for `pane.info`. `cursor` and `modes` are optional because
  /// the daemon's frozen `Info` payload does not yet carry them —
  /// callers that need byte-faithful cursor/mode assertions should fall
  /// back to `pane.read --raw` and parse the `vt`-format dump, which
  /// includes the cursor and SM/DECSM mode prologue.
  public struct PaneInfoResponse: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let shellPid: Int32
    public let pwd: String
    public let cursor: PaneCursor?
    public let modes: [String: Bool]?

    public init(
      paneID: PaneID,
      shellPid: Int32,
      pwd: String,
      cursor: PaneCursor? = nil,
      modes: [String: Bool]? = nil
    ) {
      self.paneID = paneID
      self.shellPid = shellPid
      self.pwd = pwd
      self.cursor = cursor
      self.modes = modes
    }
  }
}
