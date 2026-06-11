import Foundation

/// Length-prefix framing for JSON-RPC envelopes.
///
/// Layout: 4-byte big-endian `UInt32` length prefix, followed by exactly
/// `length` bytes of UTF-8 JSON. No trailing newline. The 32-bit prefix
/// admits frames up to ~4 GiB, but the server enforces a hard 16 MiB cap
/// per frame (exec-plan 0003 DEC-3): oversize frames throw
/// `Framing.FramingError.frameTooLarge` and the connection is closed.
public enum Framing {
  /// Hard per-frame cap. Frames larger than this are rejected.
  public static let maxFrameBytes: UInt32 = 16 * 1024 * 1024

  public enum FramingError: Error, Equatable {
    case frameTooLarge(declared: UInt32, max: UInt32)
    case malformedHeader
  }

  /// Encode a complete frame from the given JSON body. Throws if the body
  /// exceeds `maxFrameBytes`.
  public static func encode(_ body: Data) throws -> Data {
    guard body.count <= Int(maxFrameBytes) else {
      throw FramingError.frameTooLarge(declared: UInt32(truncatingIfNeeded: body.count), max: maxFrameBytes)
    }
    var out = Data(capacity: 4 + body.count)
    let length = UInt32(body.count).bigEndian
    withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
    out.append(body)
    return out
  }

  /// Attempt to decode one complete frame from the head of `buffer`.
  ///
  /// Returns the frame's body bytes and consumes them (plus the 4-byte
  /// header) from `buffer`. Returns `nil` if the buffer does not yet
  /// contain a complete frame. Throws if the length prefix declares a
  /// frame larger than `maxFrameBytes`.
  public static func decode(from buffer: inout Data) throws -> Data? {
    guard buffer.count >= 4 else { return nil }
    let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
      raw.load(as: UInt32.self).bigEndian
    }
    if length > maxFrameBytes {
      throw FramingError.frameTooLarge(declared: length, max: maxFrameBytes)
    }
    let total = 4 + Int(length)
    guard buffer.count >= total else { return nil }
    let body = buffer.subdata(in: 4..<total)
    buffer.removeSubrange(0..<total)
    return body
  }
}
