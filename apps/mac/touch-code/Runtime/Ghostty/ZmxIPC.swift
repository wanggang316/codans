import Foundation

/// Wire-protocol tag values for the zmx pane-resume daemon. Numeric values
/// MUST stay byte-for-byte aligned with `ThirdParty/zmx/src/ipc.zig`:
/// changing a value here desynchronizes Swift clients against any running
/// daemon. Add new tags by appending at the next free integer; never
/// renumber.
public nonisolated enum ZmxTag: UInt8, Sendable {
  case input = 0
  case output = 1
  case resize = 2
  case detach = 3
  case detachAll = 4
  case kill = 5
  case info = 6
  case `init` = 7
  case history = 8
  case run = 9
  case ack = 10
  case `switch` = 11
  case write = 12
  case taskComplete = 13
  case snapshot = 14
}

/// Format byte sent in the payload of a `.history` request. Mirrors
/// zmx's `util.HistoryFormat` enum: the daemon's `serializeTerminal`
/// dispatches on the same numeric values, so changing one side without
/// the other silently swaps formats. New variants land at the next
/// free integer; never renumber.
public nonisolated enum ZmxHistoryFormat: UInt8, Sendable {
  case plain = 0
  case vt = 1
  case html = 2
}

/// A single decoded IPC frame: tag plus opaque payload bytes.
public nonisolated struct ZmxFrame: Sendable, Equatable {
  public let tag: ZmxTag
  public let payload: Data

  public init(tag: ZmxTag, payload: Data = Data()) {
    self.tag = tag
    self.payload = payload
  }
}

/// Errors surfaced by ``ZmxFraming/decode(buffer:)``.
public nonisolated enum ZmxIPCError: Error, Equatable, Sendable {
  case malformedLength
  case unknownTag(UInt8)
  case payloadTooLarge(Int)
}

/// Length-prefixed framing matching `ipc.Header` in `ThirdParty/zmx/src/ipc.zig`.
///
/// On the wire, every frame is laid out as the bytes of Zig's
/// `packed struct { tag: u8, len: u32 }` (followed by `len` payload bytes).
/// The packed struct backs to u40 but `@sizeOf` rounds to 8, so the header
/// on the wire is 8 bytes: `[tag(1)][len_LE(4)][padding(3)] + payload`.
/// Padding bytes are written as zero by the daemon and ignored on read.
public nonisolated enum ZmxFraming {
  /// Length cap to refuse allocation-bomb frames from a hostile peer.
  /// Picked at 64 MiB, comfortably above any real terminal Output burst
  /// (snapshots are typically <2 MiB; bulk paste is bounded by PTY limits).
  public static let maxPayloadSize: Int = 64 * 1024 * 1024

  /// Header on the wire is 8 bytes — Zig's `packed struct { u8, u32 }`
  /// rounds to 8 due to u32 alignment. The ipc.zig wire-freeze test
  /// asserts this size; mirror the constant rather than recomputing.
  public static let headerSize: Int = 8

  public static func encode(_ frame: ZmxFrame) -> Data {
    var out = Data(capacity: headerSize + frame.payload.count)
    out.append(frame.tag.rawValue)
    var lenLE = UInt32(frame.payload.count).littleEndian
    withUnsafeBytes(of: &lenLE) { out.append(contentsOf: $0) }
    // Zero the 3 trailing padding bytes so the wire image matches what
    // zmx writes (its `Header{ ... }` initializer leaves padding zeroed).
    out.append(contentsOf: [0, 0, 0])
    if !frame.payload.isEmpty {
      out.append(frame.payload)
    }
    return out
  }

  /// Pull at most one frame from `buffer`. Returns `nil` when the buffer
  /// does not yet contain a full frame; otherwise removes the consumed
  /// bytes and returns the frame. Throws ``ZmxIPCError`` on a malformed
  /// header or unknown tag.
  public static func decode(buffer: inout Data) throws -> ZmxFrame? {
    guard buffer.count >= headerSize else { return nil }
    let tagByte = buffer[buffer.startIndex]
    let lenStart = buffer.index(buffer.startIndex, offsetBy: 1)
    let lenEnd = buffer.index(lenStart, offsetBy: 4)
    let lenSlice = buffer[lenStart..<lenEnd]
    let payloadLen32 = lenSlice.withUnsafeBytes { raw -> UInt32 in
      raw.loadUnaligned(as: UInt32.self)
    }
    let payloadLen = Int(UInt32(littleEndian: payloadLen32))
    if payloadLen < 0 {
      throw ZmxIPCError.malformedLength
    }
    if payloadLen > maxPayloadSize {
      throw ZmxIPCError.payloadTooLarge(payloadLen)
    }
    guard let tag = ZmxTag(rawValue: tagByte) else {
      throw ZmxIPCError.unknownTag(tagByte)
    }
    let total = headerSize + payloadLen
    guard buffer.count >= total else { return nil }
    let payloadStart = buffer.index(buffer.startIndex, offsetBy: headerSize)
    let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLen)
    let payload = Data(buffer[payloadStart..<payloadEnd])
    buffer.removeSubrange(buffer.startIndex..<payloadEnd)
    return ZmxFrame(tag: tag, payload: payload)
  }
}

/// Payload for ``ZmxTag/init`` and ``ZmxTag/resize`` frames. Wire shape
/// mirrors zmx's `ipc.Resize` (`packed struct { rows: u16, cols: u16 }`),
/// little-endian. Field order matches the daemon — rows then cols — so
/// `bytesToValue(ipc.Resize, payload)` round-trips on both sides.
public nonisolated struct ZmxResizePayload: Sendable, Equatable {
  public let cols: UInt16
  public let rows: UInt16

  public init(cols: UInt16, rows: UInt16) {
    self.cols = cols
    self.rows = rows
  }

  public func encode() -> Data {
    var out = Data(capacity: 4)
    var rowsLE = rows.littleEndian
    var colsLE = cols.littleEndian
    withUnsafeBytes(of: &rowsLE) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: &colsLE) { out.append(contentsOf: $0) }
    return out
  }

  public static func decode(_ data: Data) throws -> ZmxResizePayload {
    guard data.count == 4 else { throw ZmxIPCError.malformedLength }
    let rows = data.withUnsafeBytes { raw -> UInt16 in
      raw.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
    }
    let cols = data.withUnsafeBytes { raw -> UInt16 in
      raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
    }
    return ZmxResizePayload(cols: UInt16(littleEndian: cols), rows: UInt16(littleEndian: rows))
  }
}

/// Subset of zmx's `ipc.Info` decoded by the Swift client. The daemon
/// transmits the full frozen `Info` extern struct (552 bytes) — we lift
/// out only `pid` and `cwd` here; cursor/modes get added later when the
/// surface integration needs them. The decoder tolerates a payload that
/// is *exactly* `@sizeOf(ipc.Info) = 552` bytes long; any other size is
/// treated as malformed so we notice when the daemon's wire shape drifts.
///
/// Layout (matches `ipc.Info` declaration order — extern struct, so this
/// is the byte layout):
///   - clients_len: u64 @ 0
///   - pid:         i32 @ 8
///   - cmd_len:     u16 @ 12
///   - cwd_len:     u16 @ 14
///   - cmd:         [256]u8 @ 16
///   - cwd:         [256]u8 @ 272
///   - created_at:  u64 @ 528
///   - task_ended_at: u64 @ 536
///   - task_exit_code: u8 @ 544
///   - tail padding @ 545..552
public nonisolated struct ZmxInfoPayload: Sendable, Equatable {
  public let pid: Int32
  public let cwd: String

  public init(pid: Int32, cwd: String) {
    self.pid = pid
    self.cwd = cwd
  }

  /// Byte offsets/sizes from zmx's `ipc.Info` extern struct. Asserted by
  /// the daemon-side `Info wire size is frozen` test (552 bytes total).
  static let wireSize: Int = 552
  static let pidOffset: Int = 8
  static let cwdLenOffset: Int = 14
  static let cwdOffset: Int = 272
  static let cwdMax: Int = 256

  public static func decode(_ data: Data) throws -> ZmxInfoPayload {
    guard data.count == wireSize else { throw ZmxIPCError.malformedLength }
    let pid = data.withUnsafeBytes { raw -> Int32 in
      raw.loadUnaligned(fromByteOffset: pidOffset, as: Int32.self)
    }
    let cwdLenRaw = data.withUnsafeBytes { raw -> UInt16 in
      raw.loadUnaligned(fromByteOffset: cwdLenOffset, as: UInt16.self)
    }
    let cwdLen = min(Int(UInt16(littleEndian: cwdLenRaw)), cwdMax)
    let cwdStart = data.index(data.startIndex, offsetBy: cwdOffset)
    let cwdEnd = data.index(cwdStart, offsetBy: cwdLen)
    let cwdBytes = data[cwdStart..<cwdEnd]
    // Failable variant is preferred — daemon emits valid UTF-8 (POSIX path),
    // but if the payload is corrupted we want an empty cwd over a crash.
    let cwd = String(bytes: cwdBytes, encoding: .utf8) ?? ""
    return ZmxInfoPayload(pid: Int32(littleEndian: pid), cwd: cwd)
  }
}
