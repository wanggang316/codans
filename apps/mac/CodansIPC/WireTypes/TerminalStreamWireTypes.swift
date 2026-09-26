import CodansCore
import Foundation

extension IPC {
  /// `pane.attachStream` params. A streaming call: the server answers with
  /// `TerminalStreamFrame`s until either side closes. Attaching is
  /// read-only — it never sizes the pane or types into it.
  public struct PaneAttachStreamRequest: Codable, Equatable, Sendable {
    public let paneID: PaneID
    /// Scrollback rows above the screen to include in each `reset`
    /// snapshot. Nil takes the server default; the server clamps it.
    public let scrollbackRows: Int?
    /// How long the server may hold output to batch it into one frame.
    /// Nil takes the server default; the server clamps it.
    public let coalesceMillis: Int?

    public init(paneID: PaneID, scrollbackRows: Int? = nil, coalesceMillis: Int? = nil) {
      self.paneID = paneID
      self.scrollbackRows = scrollbackRows
      self.coalesceMillis = coalesceMillis
    }
  }

  /// How faithfully a `reset` snapshot reproduces the Mac's terminal.
  public enum TerminalStreamFidelity: String, Codable, Equatable, Sendable {
    /// Cursor, modes and screen exactly as the Mac has them.
    case exact
    /// Screen text and colours, but the cursor or modes may be off. Sent
    /// when the pane's session predates the observer protocol.
    case approximate
  }

  /// What one `pane.attachStream` frame carries.
  public enum TerminalStreamPayload: Equatable, Sendable {
    /// Reset the emulator to a blank `cols`×`rows` screen; the `output`
    /// frames that follow repaint it and then continue live.
    case reset(cols: Int, rows: Int, fidelity: TerminalStreamFidelity)
    /// Raw terminal bytes, in order.
    case output(Data)
    /// The pane's grid changed size at this point in the byte stream.
    case resized(cols: Int, rows: Int)
    /// Sent after a quiet period so a client can detect a half-open link.
    case heartbeat
    /// The pane's session ended; no frames follow.
    case exited(reason: String, exitCode: Int?)
    /// A kind this build does not know, from a newer server. Clients
    /// ignore it instead of failing the stream.
    case unknown(kind: String)

    public var kind: String {
      switch self {
      case .reset: return "reset"
      case .output: return "output"
      case .resized: return "resized"
      case .heartbeat: return "heartbeat"
      case .exited: return "exited"
      case .unknown(let kind): return kind
      }
    }
  }

  /// One `pane.attachStream` frame. Flat on the wire, discriminated by
  /// `kind`: `{"v": 1, "seq": 7, "epoch": 1, "kind": "output", "data": "<base64>"}`.
  ///
  /// `seq` increases by one per frame. `epoch` increases whenever the
  /// server had to drop output it could not deliver in time; every frame
  /// of a new epoch comes after a fresh `reset`, so a client never
  /// renders a stream with a hole in it.
  public struct TerminalStreamFrame: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let v: Int
    public let seq: Int
    public let epoch: Int
    public let payload: TerminalStreamPayload

    public init(seq: Int, epoch: Int, payload: TerminalStreamPayload, v: Int = Self.currentVersion) {
      self.v = v
      self.seq = seq
      self.epoch = epoch
      self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
      case v, seq, epoch, kind, cols, rows, fidelity, data, reason, exitCode
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      v = try c.decodeIfPresent(Int.self, forKey: .v) ?? Self.currentVersion
      seq = try c.decode(Int.self, forKey: .seq)
      epoch = try c.decode(Int.self, forKey: .epoch)
      let kind = try c.decode(String.self, forKey: .kind)
      switch kind {
      case "reset":
        // An unknown fidelity from a newer server is at best approximate.
        let fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
          .flatMap(TerminalStreamFidelity.init(rawValue:)) ?? .approximate
        payload = .reset(
          cols: try c.decode(Int.self, forKey: .cols),
          rows: try c.decode(Int.self, forKey: .rows),
          fidelity: fidelity)
      case "output":
        let encoded = try c.decode(String.self, forKey: .data)
        guard let data = Data(base64Encoded: encoded) else {
          throw DecodingError.dataCorruptedError(
            forKey: .data, in: c, debugDescription: "output data is not base64")
        }
        payload = .output(data)
      case "resized":
        payload = .resized(
          cols: try c.decode(Int.self, forKey: .cols),
          rows: try c.decode(Int.self, forKey: .rows))
      case "heartbeat":
        payload = .heartbeat
      case "exited":
        payload = .exited(
          reason: try c.decode(String.self, forKey: .reason),
          exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode))
      default:
        payload = .unknown(kind: kind)
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(v, forKey: .v)
      try c.encode(seq, forKey: .seq)
      try c.encode(epoch, forKey: .epoch)
      try c.encode(payload.kind, forKey: .kind)
      switch payload {
      case .reset(let cols, let rows, let fidelity):
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(fidelity, forKey: .fidelity)
      case .output(let data):
        try c.encode(data.base64EncodedString(), forKey: .data)
      case .resized(let cols, let rows):
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
      case .exited(let reason, let exitCode):
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
      case .heartbeat, .unknown:
        break
      }
    }
  }
}
